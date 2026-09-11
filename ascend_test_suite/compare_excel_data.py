#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Excel性能数据比较脚本
读取Excel文件中的性能数据并比较差值是否在20%以内，
并将比对结果按「类别/指标 × 并发×上下文」布局额外导出到Excel。
"""

from openpyxl import Workbook, load_workbook
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter
from pathlib import Path
from collections import OrderedDict
import re
import sys

from SendMsgToBot import send_summary_to_server


# 导出表中的指标定义：(唯一键, 行显示名, 源列名匹配关键字, 越高越好)
# 唯一键用于矩阵存储，避免 TTFT/TPOT/ITL 下 Mean/P50/P99 互相覆盖
METRIC_GROUPS = [
    ("系统数据", [
        ("successful_requests", "Successful requests", "Successful requests", True),
        ("qps", "QPS", "Request throughput", True),
        ("tps", "TPS", "Output token throughput", True),
        ("total_token_throughput", "Total Token throughput", "Total Token throughput", True),
    ]),
    ("TTFT(ms)", [
        ("ttft_mean", "Mean", "Mean TTFT", False),
        ("ttft_p50", "P50", "Median TTFT", False),
        ("ttft_p99", "P99", "P99 TTFT", False),
    ]),
    ("TPOT(ms)", [
        ("tpot_mean", "Mean", "Mean TPOT", False),
        ("tpot_p50", "P50", "Median TPOT", False),
        ("tpot_p99", "P99", "P99 TPOT", False),
    ]),
    ("ITL(ms)", [
        ("itl_mean", "Mean", "Mean ITL", False),
        ("itl_p50", "P50", "Median ITL", False),
        ("itl_p99", "P99", "P99 ITL", False),
    ]),
]


def read_excel_data(file_path):
    """读取Excel文件的所有sheet"""
    print(f"\n正在读取文件: {file_path}")

    wb = load_workbook(file_path, data_only=True)

    print(f"发现 {len(wb.sheetnames)} 个sheet:")
    for i, sheet_name in enumerate(wb.sheetnames, 1):
        print(f"  {i}. {sheet_name}")

    sheets_data = {}
    for sheet_name in wb.sheetnames:
        ws = wb[sheet_name]

        data = []
        for row in ws.iter_rows(values_only=True):
            data.append(row)

        sheets_data[sheet_name] = {
            'worksheet': ws,
            'data': data
        }

        print(f"\nSheet '{sheet_name}':")
        print(f"  - 行数: {ws.max_row}, 列数: {ws.max_column}")
        if len(data) > 0:
            print(f"  - 列头: {data[0]}")
            print(f"  - 前3行数据:")
            for i, row in enumerate(data[:3], 1):
                print(f"    行{i}: {row}")

    return sheets_data


def is_numeric(value):
    """检查值是否为数字"""
    if value is None:
        return False
    if isinstance(value, (int, float)):
        return not (value != value)  # 检查是否为NaN
    try:
        float(value)
        return True
    except (ValueError, TypeError):
        return False


def _normalize_batch(batch):
    """去掉 batch 中的括号部分，如 '100 (num_prompt=400)' -> '100'"""
    if batch is None:
        return None
    text = str(batch).strip()
    if '(' in text:
        text = text.split('(')[0].strip()
    return text or None


def _find_metric_header(data):
    """定位性能指标表头行及列名列表"""
    for idx, row in enumerate(data):
        if any(cell and 'Output token throughput' in str(cell) for cell in row):
            return idx, list(row)
    return 5, list(data[5]) if len(data) > 5 else []


def _match_metric_col(metric_headers, keyword):
    """按关键字在表头中查找列索引（忽略大小写与多余空格）"""
    needle = re.sub(r'\s+', ' ', keyword.strip().lower())
    for col_idx, header in enumerate(metric_headers):
        if not header:
            continue
        hay = re.sub(r'\s+', ' ', str(header).strip().lower())
        if needle in hay:
            return col_idx
    return None


def _parse_sheet_matrix(sheet_data):
    """
    将 sheet 解析为 {(context, batch): {metric_display_name: value}}
    同时返回有序的 context / batch 列表。
    """
    data = sheet_data['data']
    if not data:
        return {}, [], []

    header_row_idx, metric_headers = _find_metric_header(data)
    start_row = header_row_idx + 1

    # 预计算各指标唯一键对应的列
    metric_col_map = {}
    for _, metrics in METRIC_GROUPS:
        for metric_key, _display, keyword, _ in metrics:
            col = _match_metric_col(metric_headers, keyword)
            if col is not None:
                metric_col_map[metric_key] = col

    matrix = OrderedDict()
    contexts = []
    batches = []
    context_len = None

    for row_idx in range(start_row, len(data)):
        row = data[row_idx]
        if len(row) > 1 and row[1] is not None:
            context_len = row[1]
        batch = _normalize_batch(row[2] if len(row) > 2 else None)

        if not context_len and not batch:
            continue
        if batch is None:
            continue

        ctx = str(context_len) if context_len is not None else ""
        if ctx and ctx not in contexts:
            contexts.append(ctx)
        if batch not in batches:
            batches.append(batch)

        key = (ctx, batch)
        values = {}
        for metric_key, col_idx in metric_col_map.items():
            if col_idx < len(row) and is_numeric(row[col_idx]):
                values[metric_key] = float(row[col_idx])
        matrix[key] = values

    return matrix, contexts, batches


def _signed_percent(new_val, base_val):
    """相对基线的有符号百分比变化: (当前 - 基线) / |基线| * 100"""
    if base_val is None or base_val == 0 or new_val is None:
        return None
    return ((new_val - base_val) / abs(base_val)) * 100


def _format_pct_with_arrow(pct, digits=1):
    """将有符号百分比格式化为带升降箭头的文本（▲ 上升 / ▼ 下降）。"""
    if pct is None:
        return ""
    if abs(pct) < 1e-9:
        return f"● {0:.{digits}f}%"
    arrow = "▲" if pct > 0 else "▼"
    return f"{arrow} {abs(pct):.{digits}f}%"


def _format_delta_text(pct, higher_is_better):
    """
    返回 (文本, 是否改善, 字体颜色RGB)。
    箭头表示数值升降，颜色表示相对指标方向是否改善。
    """
    if pct is None:
        return ("", None, "000000")
    text = _format_pct_with_arrow(pct, digits=1)
    if abs(pct) < 1e-9:
        return (text, None, "666666")
    improved = (pct > 0) if higher_is_better else (pct < 0)
    color = "00B050" if improved else "FF0000"
    return (text, improved, color)


def _shorten_context(ctx):
    """将上下文长度标签适当缩短，便于表头展示（如 30000+2048 -> 30K+2K）"""
    text = str(ctx)

    def _tok(part):
        try:
            n = int(part)
        except (TypeError, ValueError):
            return part
        if n >= 1024 and n % 1024 == 0:
            return f"{n // 1024}K"
        if n >= 1000 and n % 1000 == 0:
            return f"{n // 1000}K"
        return str(n)

    if '+' in text:
        left, right = text.split('+', 1)
        return f"{_tok(left.strip())}+{_tok(right.strip())}"
    return _tok(text) if str(text).isdigit() else text


def export_comparison_excel(
    matrix_new,
    matrix_base,
    contexts,
    batches,
    baseline_label,
    new_label,
    model_name,
    output_path,
):
    """
    按截图样式导出比对结果：
    - 列：按 Batch 分组 (C-{batch})，子列为上下文长度
    - 行：类别 + 指标；每个指标两行（新值 / ∟ vs 基线）
    """
    wb = Workbook()
    ws = wb.active
    ws.title = "性能对比"

    # 样式
    header_fill = PatternFill("solid", fgColor="1F4E79")
    header_font = Font(bold=True, color="FFFFFF", name="微软雅黑", size=11)
    category_fill = PatternFill("solid", fgColor="2F5496")
    category_font = Font(bold=True, color="FFFFFF", name="微软雅黑", size=10)
    metric_fill = PatternFill("solid", fgColor="D6DCE4")
    metric_font = Font(bold=True, name="微软雅黑", size=10)
    vs_font = Font(name="微软雅黑", size=9, color="595959")
    value_font = Font(name="微软雅黑", size=10)
    alt_fill = PatternFill("solid", fgColor="DEEBF7")
    white_fill = PatternFill("solid", fgColor="FFFFFF")
    center = Alignment(horizontal="center", vertical="center", wrap_text=True)
    left = Alignment(horizontal="left", vertical="center")
    thin = Border(
        left=Side(style="thin", color="B4B4B4"),
        right=Side(style="thin", color="B4B4B4"),
        top=Side(style="thin", color="B4B4B4"),
        bottom=Side(style="thin", color="B4B4B4"),
    )

    # ---- 表头 ----
    # A1:B2 合并写「类别 / 指标」
    ws.merge_cells(start_row=1, start_column=1, end_row=2, end_column=1)
    cell = ws.cell(1, 1, value="类别")
    cell.fill = header_fill
    cell.font = header_font
    cell.alignment = center
    cell.border = thin
    ws.cell(2, 1).border = thin
    ws.cell(2, 1).fill = header_fill

    ws.merge_cells(start_row=1, start_column=2, end_row=2, end_column=2)
    cell = ws.cell(1, 2, value="指标")
    cell.fill = header_fill
    cell.font = header_font
    cell.alignment = center
    cell.border = thin
    ws.cell(2, 2).border = thin
    ws.cell(2, 2).fill = header_fill

    # 列映射: (context, batch) -> col_idx
    col_map = {}
    col = 3
    for batch in batches:
        start_col = col
        for ctx in contexts:
            col_map[(ctx, batch)] = col
            sub = ws.cell(2, col, value=_shorten_context(ctx))
            sub.fill = header_fill
            sub.font = header_font
            sub.alignment = center
            sub.border = thin
            col += 1
        end_col = col - 1
        if end_col >= start_col:
            if end_col > start_col:
                ws.merge_cells(
                    start_row=1, start_column=start_col,
                    end_row=1, end_column=end_col,
                )
            top = ws.cell(1, start_col, value=f"C-{batch}")
            top.fill = header_fill
            top.font = header_font
            top.alignment = center
            top.border = thin
            for c in range(start_col, end_col + 1):
                ws.cell(1, c).fill = header_fill
                ws.cell(1, c).border = thin
                ws.cell(1, c).font = header_font

    total_cols = col - 1

    # ---- 数据行 ----
    row = 3
    group_alt = False  # 按指标组交替底色

    for group_name, metrics in METRIC_GROUPS:
        # 过滤掉源数据中完全不存在的指标
        present = [
            m for m in metrics
            if any(
                m[0] in matrix_new.get(k, {}) or m[0] in matrix_base.get(k, {})
                for k in set(matrix_new) | set(matrix_base)
            )
        ]
        if not present:
            continue

        group_start = row
        for metric_key, display_name, _keyword, higher_is_better in present:
            group_alt = not group_alt
            row_fill = alt_fill if group_alt else white_fill

            # 主值行
            ws.cell(row, 2, value=display_name).font = metric_font
            ws.cell(row, 2).fill = metric_fill
            ws.cell(row, 2).alignment = center
            ws.cell(row, 2).border = thin

            for (ctx, batch), cidx in col_map.items():
                new_val = matrix_new.get((ctx, batch), {}).get(metric_key)
                cell = ws.cell(row, cidx)
                cell.fill = row_fill
                cell.alignment = center
                cell.border = thin
                cell.font = value_font
                if new_val is not None:
                    cell.value = round(new_val, 2)
                    cell.number_format = "0.00"

            value_row = row
            row += 1

            # vs 基线行
            vs_label = f"∟ vs {baseline_label}"
            ws.cell(row, 2, value=vs_label).font = vs_font
            ws.cell(row, 2).fill = row_fill
            ws.cell(row, 2).alignment = left
            ws.cell(row, 2).border = thin

            for (ctx, batch), cidx in col_map.items():
                new_val = matrix_new.get((ctx, batch), {}).get(metric_key)
                base_val = matrix_base.get((ctx, batch), {}).get(metric_key)
                pct = _signed_percent(new_val, base_val)
                text, _improved, color = _format_delta_text(pct, higher_is_better)
                cell = ws.cell(row, cidx, value=text if text else None)
                cell.fill = row_fill
                cell.alignment = center
                cell.border = thin
                cell.font = Font(name="微软雅黑", size=9, color=color, bold=True)

            # 主值行的类别列占位（稍后合并）
            for r in (value_row, row):
                cat_cell = ws.cell(r, 1)
                cat_cell.fill = category_fill
                cat_cell.border = thin

            row += 1

        group_end = row - 1
        if group_end >= group_start:
            if group_end > group_start:
                ws.merge_cells(
                    start_row=group_start, start_column=1,
                    end_row=group_end, end_column=1,
                )
            cell = ws.cell(group_start, 1, value=group_name)
            cell.fill = category_fill
            cell.font = category_font
            cell.alignment = center

    # 列宽 / 行高 / 冻结
    ws.column_dimensions['A'].width = 14
    ws.column_dimensions['B'].width = 22
    for c in range(3, total_cols + 1):
        ws.column_dimensions[get_column_letter(c)].width = 12
    ws.row_dimensions[1].height = 22
    ws.row_dimensions[2].height = 22
    ws.freeze_panes = "C3"

    # 元信息 sheet
    meta = wb.create_sheet("说明", 1)
    meta['A1'] = "模型"
    meta['B1'] = model_name
    meta['A2'] = "当前版本 (主值)"
    meta['B2'] = new_label
    meta['A3'] = "基线版本 (vs)"
    meta['B3'] = baseline_label
    meta['A4'] = "说明"
    meta['B4'] = (
        "主值行为当前版本数据；「∟ vs ...」为相对基线的有符号百分比变化。"
        "▲/▼ 表示数值升降；绿色表示相对该指标方向改善，红色表示变差。"
        "吞吐类越高越好，延迟类越低越好。"
    )
    meta.column_dimensions['A'].width = 18
    meta.column_dimensions['B'].width = 80

    # 明细 sheet（便于筛选）
    detail = wb.create_sheet("明细", 2)
    detail_headers = [
        "上下文长度", "Batch", "类别", "指标",
        f"{new_label}_值", f"{baseline_label}_值",
        "差值", "百分比差异(%)", "方向",
    ]
    for i, h in enumerate(detail_headers, 1):
        cell = detail.cell(1, i, value=h)
        cell.fill = header_fill
        cell.font = header_font
        cell.alignment = center
        cell.border = thin

    drow = 2
    for batch in batches:
        for ctx in contexts:
            for group_name, metrics in METRIC_GROUPS:
                for metric_key, display_name, _kw, higher_is_better in metrics:
                    new_val = matrix_new.get((ctx, batch), {}).get(metric_key)
                    base_val = matrix_base.get((ctx, batch), {}).get(metric_key)
                    if new_val is None and base_val is None:
                        continue
                    pct = _signed_percent(new_val, base_val)
                    text, improved, _ = _format_delta_text(pct, higher_is_better)
                    direction = (
                        "改善" if improved else
                        ("持平" if improved is None and pct is not None else
                         ("变差" if improved is False else ""))
                    )
                    diff = None
                    if new_val is not None and base_val is not None:
                        diff = round(new_val - base_val, 4)
                    values = [
                        ctx, batch, group_name, display_name,
                        round(new_val, 4) if new_val is not None else None,
                        round(base_val, 4) if base_val is not None else None,
                        diff,
                        round(pct, 2) if pct is not None else None,
                        direction,
                    ]
                    for i, v in enumerate(values, 1):
                        cell = detail.cell(drow, i, value=v)
                        cell.border = thin
                        cell.alignment = center
                    drow += 1

    for c in range(1, len(detail_headers) + 1):
        detail.column_dimensions[get_column_letter(c)].width = 16
    detail.freeze_panes = "A2"

    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    wb.save(output_path)
    print(f"\n📁 比对结果已导出到: {output_path}")
    return output_path


def compare_two_sheets(sheet1_data, sheet2_data, image_version_1, image_version_2, threshold, model_name, output_excel=None):
    sheet1_name = f"文件1-{image_version_1}"
    sheet2_name = f"文件2-{image_version_2}"

    """比较两个sheet的数据，检查数值的差值是否在阈值内"""
    print(f"\n{'='*100}")
    print(f"比较 '{sheet1_name}' 和 '{sheet2_name}' 的性能测试数据")
    print(f"{'='*100}")

    data1 = sheet1_data['data']
    data2 = sheet2_data['data']

    if len(data1) == 0 or len(data2) == 0:
        print("警告: 其中一个sheet为空")
        return

    # 找到性能指标表头行（包含"Output token throughput"等）
    header_row_idx = -1
    metric_headers = []

    for idx, row in enumerate(data1):
        if any(cell and 'Output token throughput' in str(cell) for cell in row):
            metric_headers = list(row)  # 转换为列表以便修改
            header_row_idx = idx
            print(f"\n找到性能指标表头行: 第{idx+1}行")
            print(f"性能指标列: {[str(h) for h in metric_headers if h]}")
            break

    if header_row_idx == -1:
        print("警告: 未找到性能指标表头，将从第6行开始比较")
        header_row_idx = 5  # 默认从第6行开始
        metric_headers = list(data1[header_row_idx]) if len(data1) > header_row_idx else []

    # 找到最长的列名并填充其他列名以实现对齐
    if metric_headers:
        max_length = max(len(str(h)) for h in metric_headers if h)
        metric_headers = [str(h).ljust(max_length) if h else h for h in metric_headers]
        print(f"列名对齐完成，最大长度: {max_length}")
        print(f"对齐后的列名: {[repr(h) for h in metric_headers if h]}")

    comparison_results = []
    exceed_threshold_count = 0
    total_comparisons = 0

    start_row = header_row_idx + 1
    min_rows = min(len(data1), len(data2))
    min_cols = min(len(data1[0]) if data1 else 0, len(data2[0]) if data2 else 0)

    print(f"\n开始比较性能数据: 从第{start_row+1}行到第{min_rows}行")

    context_len = None
    for row_idx in range(start_row, min_rows):
        if len(data1[row_idx]) > 1 and data1[row_idx][1] is not None:
            context_len = data1[row_idx][1]
        batch = data1[row_idx][2] if len(data1[row_idx]) > 2 else None

        if batch and '(' in str(batch):
            batch = str(batch).split('(')[0].strip()

        if not context_len and not batch:
            continue

        row_label = f"{context_len or ''} | {batch or ''}".strip(' |')

        for col_idx in range(3, min_cols):
            val1 = data1[row_idx][col_idx] if col_idx < len(data1[row_idx]) else None
            val2 = data2[row_idx][col_idx] if col_idx < len(data2[row_idx]) else None

            if is_numeric(val1) and is_numeric(val2):
                # 文件1=当前版本，文件2=基线；百分比统一为相对基线
                new_val = float(val1)
                base_val = float(val2)

                if base_val == 0:
                    continue

                signed_pct = _signed_percent(new_val, base_val)
                if signed_pct is None:
                    continue

                signed_diff = new_val - base_val
                abs_pct = abs(signed_pct)

                within_threshold = abs_pct <= (threshold * 100)
                total_comparisons += 1

                if not within_threshold:
                    exceed_threshold_count += 1

                metric_name = metric_headers[col_idx] if col_idx < len(metric_headers) and metric_headers[col_idx] else f"列{col_idx}"

                result = {
                    '测试配置': row_label,
                    '性能指标': str(metric_name).strip(),
                    f'{sheet1_name}_值': round(new_val, 4),
                    f'{sheet2_name}_值': round(base_val, 4),
                    '差值': round(signed_diff, 4),
                    '相对基线(%)': signed_pct,
                    '相对基线显示': _format_pct_with_arrow(signed_pct, digits=1),
                    f'在{int(threshold*100)}%以内': '✓' if within_threshold else '✗'
                }
                comparison_results.append(result)

    # 打印结果
    if comparison_results:
        print(f"\n性能数据比较结果 (共 {len(comparison_results)} 条):")
        print(f"\n{'='*170}")

        pct_header = f"相对基线({image_version_2})"
        print(f"{'测试配置':<25} {'性能指标':<30} {sheet1_name+'_值':<15} {sheet2_name+'_值':<15} {'差值':<12} {pct_header:<16} {'在阈值内':<8}")
        print(f"{'-'*140}")

        for result in comparison_results:
            print(
                f"{result['测试配置']:<25} {result['性能指标']:<30} "
                f"{result[f'{sheet1_name}_值']:<15} {result[f'{sheet2_name}_值']:<15} "
                f"{result['差值']:<12} {result['相对基线显示']:<16} "
                f"{result[f'在{int(threshold*100)}%以内']:<8}"
            )

        summary = ""
        print(f"\n{'='*170}")
        print(f"\n📊 统计信息:")
        summary += f"\n📊 统计信息:\n"
        summary += f"  （百分比均为相对基线 {image_version_2}：▲上升 / ▼下降）\n"
        print(f"  （百分比均为相对基线 {image_version_2}：▲上升 / ▼下降）")
        print(f"  ✓ 总比较次数: {total_comparisons}")
        summary += f"  ✓ 总比较次数: {total_comparisons}\n"
        print(f"  ✓ 在{int(threshold*100)}%阈值内: {total_comparisons - exceed_threshold_count} ({(total_comparisons - exceed_threshold_count)/total_comparisons*100:.1f}%)")
        summary += f"  ✓ 在{int(threshold*100)}%阈值内: {total_comparisons - exceed_threshold_count} ({(total_comparisons - exceed_threshold_count)/total_comparisons*100:.1f}%)\n"
        print(f"  ✗ 超出阈值: {exceed_threshold_count} ({exceed_threshold_count/total_comparisons*100:.1f}%)")
        summary += f"  ✗ 超出阈值: {exceed_threshold_count} ({exceed_threshold_count/total_comparisons*100:.1f}%)\n"

        if exceed_threshold_count > 0:
            print(f"\n⚠️  警告: 有 {exceed_threshold_count} 条性能数据相对基线变化超过 {int(threshold*100)}%!")
            summary += f"\n⚠️  警告: 有 {exceed_threshold_count} 条性能数据相对基线变化超过 {int(threshold*100)}%!\n"
            print(f"\n超出阈值的数据详情:")
            summary += f"\n超出阈值的数据详情:\n"
            print(f"{'-'*140}")
            summary += f"{'-'*145}\n"
            print(f"{'测试配置':<25} {'性能指标':<30} {sheet1_name+'_值':<15} {sheet2_name+'_值':<15} {'差值':<12} {pct_header:<16}")
            summary += f"{'测试配置':<25} {'性能指标':<30} {sheet1_name+'_值':<15} {sheet2_name+'_值':<15} {'差值':<12} {pct_header:<16}\n"
            print(f"{'-'*140}")
            summary += f"{'-'*145}\n"
            for result in comparison_results:
                if result[f'在{int(threshold*100)}%以内'] == '✗':
                    line = (
                        f"{result['测试配置']:<25} {result['性能指标']:<30} "
                        f"{result[f'{sheet1_name}_值']:<15} {result[f'{sheet2_name}_值']:<15} "
                        f"{result['差值']:<12} {result['相对基线显示']:<16}"
                    )
                    print(line)
                    summary += line + "\n"
            summary += f"{'-'*145}\n"
        else:
            print(f"\n✅ 太棒了！所有性能数据相对基线的变化都在 {int(threshold*100)}% 以内!")
            summary += f"\n✅ 太棒了！所有性能数据相对基线的变化都在 {int(threshold*100)}% 以内!"

        print("\n")
        send_summary_to_server(image_version_1 + " vs " + image_version_2, model_name, summary)
    else:
        print("⚠️  没有找到可比较的性能数值数据")

    # 额外导出截图样式的 Excel（主值=文件1/当前版本，vs=文件2/基线）
    matrix_new, contexts_new, batches_new = _parse_sheet_matrix(sheet1_data)
    matrix_base, contexts_base, batches_base = _parse_sheet_matrix(sheet2_data)

    contexts = list(OrderedDict.fromkeys(contexts_new + contexts_base))
    batches = list(OrderedDict.fromkeys(batches_new + batches_base))

    if matrix_new or matrix_base:
        if output_excel is None:
            safe_model = re.sub(r'[\\/:*?"<>|]', '_', str(model_name))
            safe_v1 = re.sub(r'[\\/:*?"<>|]', '_', str(image_version_1))
            safe_v2 = re.sub(r'[\\/:*?"<>|]', '_', str(image_version_2))
            output_excel = str(
                Path.cwd() / f"compare_{safe_model}_{safe_v1}_vs_{safe_v2}.xlsx"
            )
        export_comparison_excel(
            matrix_new=matrix_new,
            matrix_base=matrix_base,
            contexts=contexts,
            batches=batches,
            baseline_label=image_version_2,
            new_label=image_version_1,
            model_name=model_name,
            output_path=output_excel,
        )

    return comparison_results if comparison_results else None


def main():
    # 文件路径
    if len(sys.argv) < 6:
        print(
            "Usage: python compare_excel_data.py <model name> "
            "<docker version 1> <file path 1> <docker version 2> <file path 2> "
            "[output excel path]"
        )
        sys.exit(1)

    model_name = sys.argv[1]
    image_version_1 = sys.argv[2]
    file_path_1 = sys.argv[3]
    image_version_2 = sys.argv[4]
    file_path_2 = sys.argv[5]
    output_excel = sys.argv[6] if len(sys.argv) > 6 else None

    # 读取Excel数据文件
    print(f"\n文件1: {file_path_1}")
    sheets_data1 = read_excel_data(file_path_1)

    print(f"\n文件2: {file_path_2}")
    sheets_data2 = read_excel_data(file_path_2)

    sheet_names1 = list(sheets_data1.keys())
    sheet_names2 = list(sheets_data2.keys())

    # 默认输出到文件1同目录
    if output_excel is None:
        safe_model = re.sub(r'[\\/:*?"<>|]', '_', str(model_name))
        safe_v1 = re.sub(r'[\\/:*?"<>|]', '_', str(image_version_1))
        safe_v2 = re.sub(r'[\\/:*?"<>|]', '_', str(image_version_2))
        output_excel = str(
            Path(file_path_1).resolve().parent
            / f"compare_{safe_model}_{safe_v1}_vs_{safe_v2}.xlsx"
        )

    compare_two_sheets(
        sheets_data1[sheet_names1[0]],
        sheets_data2[sheet_names2[0]],
        image_version_1,
        image_version_2,
        0.2,
        model_name,
        output_excel=output_excel,
    )

    return sheets_data1, sheets_data2


if __name__ == "__main__":
    sheets_data = main()
