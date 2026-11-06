# -*- coding: utf-8 -*-
"""生成 2026-11-05 决赛联调用的课程 / DDL / 错题测试素材。

数据全部为虚构，且刻意不复用 演示测试数据 里已有的
「数据结构 / 操作系统 / 计算机网络 / 高等数学」四门课与旧 DDL 标题。
运行：
    python tools/generate_final_test_data.py
输出：
    演示测试数据/决赛联调-20261105/
"""

from __future__ import annotations

import csv
import io
import json
import re
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "演示测试数据" / "决赛联调-20261105"
IMG_DIR = OUT / "错题"

# ---------------------------------------------------------------- 数据

COURSES = [
    {"courseName": "数据库系统原理", "examDate": "2026-11-24", "priority": "高",
     "studyHours": 2, "status": "近期复习不足"},
    {"courseName": "概率论与数理统计", "examDate": "2026-11-19", "priority": "高",
     "studyHours": 1, "status": "近期复习不足"},
    {"courseName": "编译原理", "examDate": "2026-11-27", "priority": "高",
     "studyHours": 5, "status": "近期复习良好"},
    {"courseName": "软件工程导论", "examDate": "2026-12-03", "priority": "中",
     "studyHours": 4, "status": "近期复习正常"},
    {"courseName": "大学英语（四）", "examDate": "2026-12-15", "priority": "中",
     "studyHours": 3, "status": "近期复习正常"},
    {"courseName": "马克思主义基本原理", "examDate": "2026-12-28", "priority": "低",
     "studyHours": 1, "status": "近期复习不足"},
]

DDLS = [
    {"courseName": "概率论与数理统计", "title": "第七章 参数估计习题（含附加题）",
     "dueDate": "2026-11-07", "priority": "高", "estimatedMinutes": 50},
    {"courseName": "数据库系统原理", "title": "SQL 查询优化实验报告",
     "dueDate": "2026-11-09", "priority": "高", "estimatedMinutes": 75},
    {"courseName": "大学英语（四）", "title": "Unit 6 听力精听与转写",
     "dueDate": "2026-11-11", "priority": "低", "estimatedMinutes": 25},
    {"courseName": "编译原理", "title": "LL(1) 分析表构造作业",
     "dueDate": "2026-11-12", "priority": "高", "estimatedMinutes": 80},
    {"courseName": "软件工程导论", "title": "需求规格说明书初稿",
     "dueDate": "2026-11-13", "priority": "中", "estimatedMinutes": 90},
    {"courseName": "大学英语（四）", "title": "议论文互评（第二稿）",
     "dueDate": "2026-11-15", "priority": "中", "estimatedMinutes": 40},
    {"courseName": "概率论与数理统计", "title": "历年真题限时训练（2019 卷）",
     "dueDate": "2026-11-18", "priority": "中", "estimatedMinutes": 120},
    {"courseName": "马克思主义基本原理", "title": "实践报告：乡村振兴调研提纲",
     "dueDate": "2026-11-20", "priority": "中", "estimatedMinutes": 60},
    {"courseName": "数据库系统原理", "title": "事务隔离级别对比（小组）",
     "dueDate": "2026-11-23", "priority": "低", "estimatedMinutes": 45},
    {"courseName": "软件工程导论", "title": "团队项目迭代二演示",
     "dueDate": "2026-11-30", "priority": "低", "estimatedMinutes": 30},
]


# ---------------------------------------------------------------- 文本文件

def write_csv(path: Path, header: list[str], rows: list[list[object]],
              *, bom: bool = False, delimiter: str = ",") -> None:
    buf = io.StringIO()
    writer = csv.writer(buf, delimiter=delimiter, lineterminator="\n",
                        quoting=csv.QUOTE_MINIMAL)
    writer.writerow(header)
    writer.writerows(rows)
    text = ("\ufeff" if bom else "") + buf.getvalue()
    path.write_text(text, encoding="utf-8", newline="")


def write_text(path: Path, text: str) -> None:
    path.write_text(text.rstrip() + "\n", encoding="utf-8", newline="")


def course_rows(courses: list[dict]) -> list[list[object]]:
    return [[c["courseName"], c["examDate"], c["priority"], c["studyHours"], c["status"]]
            for c in courses]


def ddl_rows(ddls: list[dict]) -> list[list[object]]:
    return [[d["courseName"], d["title"], d["dueDate"], d["priority"], d["estimatedMinutes"]]
            for d in ddls]


def generate_text_files() -> None:
    OUT.mkdir(parents=True, exist_ok=True)

    # 01 标准 CSV：Excel 导出常见写法，带 UTF-8 BOM
    write_csv(OUT / "01-课表-标准CSV.csv",
              ["课程名称", "考试日期", "优先级", "学习时长", "复习状态"],
              course_rows(COURSES), bom=True)

    # 02 宽松格式：别名表头 + 多种日期写法 + 留空 priority/status 让程序推断
    relaxed = [
        ["概率论与数理统计", "2026/11/19", "", 1, ""],
        ["数据库系统原理", "11月24日", "", 2, ""],
        ["编译原理", "2026.11.27", "高", 5, "近期复习良好"],
        ["软件工程导论", "2026年12月3日", "中", 4, "近期复习正常"],
        ["大学英语（四）", "12月15日", "", 3, ""],
    ]
    write_csv(OUT / "02-课表-宽松格式.csv",
              ["科目", "考试时间", "重要程度", "每周学时", "复习进度"],
              relaxed)

    # 03 无表头：第 2 列是日期，解析器应识别为纯数据
    write_csv(OUT / "03-课表-无表头.csv",
              ["马克思主义基本原理", "2026-12-28", "低", 1, "近期复习不足"],
              [["大学英语（四）", "2026-12-15", "中", 3, "近期复习正常"],
               ["软件工程导论", "2026-12-03", "中", 4, "近期复习正常"],
               ["编译原理", "2026-11-27", "高", 5, "近期复习良好"]])

    # 04 课程 JSON
    write_text(OUT / "04-课表-完整JSON.json",
               json.dumps({"courses": COURSES}, ensure_ascii=False, indent=2))

    # 05 粘贴用课程文本（与 04 同一组数据，只是走粘贴入口）
    write_text(OUT / "05-课表-粘贴用.txt",
               json.dumps({"courses": COURSES}, ensure_ascii=False, indent=2))

    # 06 标准 DDL CSV，带 BOM
    write_csv(OUT / "06-DDL-标准CSV.csv",
              ["课程名称", "作业标题", "截止日期", "优先级", "预计时长"],
              ddl_rows(DDLS), bom=True)

    # 07 含逗号、括号、破折号的字段，验证引号转义
    quoted = [
        ["概率论与数理统计", "第七章 参数估计习题（含附加题）, 第 3、5、7 题",
         "2026-11-07", "高", 50],
        ["数据库系统原理", "SQL 查询优化实验报告（含执行计划, 索引对比）",
         "2026-11-09", "高", 75],
        ["软件工程导论", "需求规格说明书初稿（第 1–3 章, 含用例图）",
         "2026-11-13", "中", 90],
        ["马克思主义基本原理", "实践报告：乡村振兴调研提纲（提纲, 访谈记录）",
         "2026-11-20", "中", 60],
    ]
    write_csv(OUT / "07-DDL-引号逗号.csv",
              ["课程名称", "作业标题", "截止日期", "优先级", "预计时长"], quoted)

    # 08 制表符分隔（Excel / 教务网页直接复制），带 BOM
    tsv = [
        ["大学英语（四）", "Unit 6 听力精听与转写", "2026-11-11", "低", 25],
        ["编译原理", "LL(1) 分析表构造作业", "2026-11-12", "高", 80],
        ["大学英语（四）", "议论文互评（第二稿）", "2026-11-15", "中", 40],
        ["概率论与数理统计", "历年真题限时训练（2019 卷）", "2026-11-18", "中", 120],
        ["数据库系统原理", "事务隔离级别对比（小组）", "2026-11-23", "低", 45],
    ]
    write_csv(OUT / "08-DDL-制表符.csv",
              ["课程名称", "作业标题", "截止日期", "优先级", "预计时长"],
              tsv, bom=True, delimiter="\t")

    # 09 DDL JSON
    write_text(OUT / "09-DDL-完整JSON.json",
               json.dumps({"ddls": DDLS}, ensure_ascii=False, indent=2))

    # 10 粘贴用 DDL 文本
    write_text(OUT / "10-DDL-粘贴用.txt",
               json.dumps({"ddls": DDLS}, ensure_ascii=False, indent=2))

    # 11 合并容器：一个文件同时含课程与 DDL，分两次、选对类型各导一次
    write_text(OUT / "11-课程与DDL-合并JSON.json",
               json.dumps({"courses": COURSES, "ddls": DDLS}, ensure_ascii=False, indent=2))

    # 90 负样例：日期认不出来，应如实报错，方便演示错误提示
    write_csv(OUT / "90-错误样例-日期待定.csv",
              ["课程名称", "考试日期", "优先级", "学习时长", "复习状态"],
              [["数字信号处理", "待定", "高", 2, "近期复习不足"],
               ["工程经济学", "下周三", "中", 3, "近期复习正常"]])


# ---------------------------------------------------------------- 图片

FONT_REG = r"C:\Windows\Fonts\msyh.ttc"
FONT_BOLD = r"C:\Windows\Fonts\msyhbd.ttc"
FONT_MONO = r"C:\Windows\Fonts\consola.ttf"
FONT_HAND = r"C:\Windows\Fonts\simkai.ttf"

PAPER = "#FBFAF6"
INK = "#1F2328"
MUTED = "#6B7280"
LINE = "#D9D5CA"
ACCENT = "#B23A32"
ANSWER_BG = "#FFF6DE"
ANSWER_LINE = "#E3C47B"
ANSWER_INK = "#1F4E79"

_cache: dict[tuple[str, int], ImageFont.FreeTypeFont] = {}


def font(path: str, size: int) -> ImageFont.FreeTypeFont:
    key = (path, size)
    if key not in _cache:
        _cache[key] = ImageFont.truetype(path, size)
    return _cache[key]


def text_width(draw: ImageDraw.ImageDraw, text: str, f: ImageFont.FreeTypeFont) -> float:
    return draw.textlength(text, font=f)


TOKEN_RE = re.compile(r"[A-Za-z0-9_\-.,;:'\"()\[\]{}/<>=+*%$#@!?&|~`]+|\s+|.", re.S)


def wrap(draw: ImageDraw.ImageDraw, text: str, f: ImageFont.FreeTypeFont,
         max_width: float) -> list[str]:
    """中英混排按宽度折行；英文单词尽量不拆开。"""
    lines: list[str] = []
    current = ""
    for token in TOKEN_RE.findall(text):
        if token == "\n":
            lines.append(current.rstrip())
            current = ""
            continue
        candidate = current + token
        if text_width(draw, candidate, f) <= max_width or not current:
            current = candidate
        else:
            lines.append(current.rstrip())
            current = token.lstrip()
    if current.strip():
        lines.append(current.rstrip())
    return lines or [""]


def draw_wrapped(draw: ImageDraw.ImageDraw, x: int, y: int, text: str,
                 f: ImageFont.FreeTypeFont, max_width: float, line_height: int,
                 fill: str = INK) -> int:
    for line in wrap(draw, text, f, max_width):
        draw.text((x, y), line, font=f, fill=fill)
        y += line_height
    return y


def cross(draw: ImageDraw.ImageDraw, x: int, y: int, size: int = 22,
          color: str = "#C0392B", width: int = 4) -> None:
    draw.line((x, y, x + size, y + size), fill=color, width=width)
    draw.line((x + size, y, x, y + size), fill=color, width=width)


def new_page(width: int, height: int, course: str, tag: str) -> tuple[Image.Image, ImageDraw.ImageDraw]:
    image = Image.new("RGB", (width, height), PAPER)
    draw = ImageDraw.Draw(image)
    draw.rectangle((26, 26, width - 26, height - 26), outline=LINE, width=2)
    draw.rectangle((26, 26, 34, height - 26), fill=ACCENT)
    draw.text((64, 56), "2026 秋季学期 · 期末复习", font=font(FONT_REG, 21), fill=MUTED)
    draw.text((64, 88), course, font=font(FONT_BOLD, 31), fill=INK)
    right = f"错题整理 · {tag}"
    draw.text((width - 64 - text_width(draw, right, font(FONT_REG, 21)), 94),
              right, font=font(FONT_REG, 21), fill=MUTED)
    draw.line((64, 146, width - 64, 146), fill=LINE, width=2)
    return image, draw


def finish_page(image: Image.Image, draw: ImageDraw.ImageDraw, page: str) -> None:
    width, height = image.size
    draw.line((64, height - 78, width - 64, height - 78), fill=LINE, width=1)
    draw.text((64, height - 60), "知学 Mate · 测试用错题", font=font(FONT_REG, 18), fill=MUTED)
    draw.text((width - 64 - text_width(draw, page, font(FONT_REG, 18)), height - 60),
              page, font=font(FONT_REG, 18), fill=MUTED)


def draw_stem(draw: ImageDraw.ImageDraw, x: int, y: int, number: int, stem: str,
              size: int = 29, max_width: int = 940) -> int:
    f = font(FONT_REG, size)
    draw.text((x, y - 4), f"{number}.", font=font(FONT_BOLD, size), fill=ACCENT)
    y = draw_wrapped(draw, x + 52, y, stem, f, max_width - 52, int(size * 1.55))
    return y


def draw_options(draw: ImageDraw.ImageDraw, x: int, y: int, options: list[str],
                 size: int = 26, mono: bool = False, two_col: bool = True,
                 max_width: int = 940) -> int:
    f = font(FONT_MONO if mono else FONT_REG, size)
    letters = "ABCD"
    if two_col and max(len(o) for o in options) <= 18:
        col_w = (max_width - 52) // 2
        for i, option in enumerate(options):
            col = i % 2
            row = i // 2
            ox = x + 52 + col * col_w
            oy = y + row * int(size * 1.65)
            draw.text((ox, oy), f"{letters[i]}.", font=font(FONT_BOLD, size), fill=INK)
            draw.text((ox + 38, oy), option, font=f, fill=INK)
        return y + ((len(options) + 1) // 2) * int(size * 1.65)
    line_h = int(size * 1.5)
    for i, option in enumerate(options):
        draw.text((x + 52, y), f"{letters[i]}.", font=font(FONT_BOLD, size), fill=INK)
        y = draw_wrapped(draw, x + 52 + int(text_width(draw, "A.", font(FONT_BOLD, size)) + 10),
                         y, option, f, max_width - 52 - 40, line_h)
        y += 6
    return y


def draw_answer(draw: ImageDraw.ImageDraw, x: int, y: int, student: str,
                width: int = 940, note: str = "（未订正）") -> int:
    box_h = 72
    draw.rounded_rectangle((x, y, x + width, y + box_h), radius=10,
                           fill=ANSWER_BG, outline=ANSWER_LINE, width=2)
    draw.text((x + 22, y + 14), "我的答案：", font=font(FONT_REG, 24), fill=MUTED)
    answer = f"{student}"
    draw.text((x + 22 + text_width(draw, "我的答案：", font(FONT_REG, 24)), y + 8),
              answer, font=font(FONT_HAND, 34), fill=ANSWER_INK)
    ax = x + 22 + text_width(draw, "我的答案：" + answer, font(FONT_REG, 24)) + 16
    cross(draw, int(ax), y + 24, 22)
    draw.text((int(ax) + 36, y + 20), note, font=font(FONT_REG, 20), fill=MUTED)
    return y + box_h


def render_single(path: Path, course: str, tag: str, stem: str,
                  options: list[str], student: str,
                  *, mono: bool = False, size: int = 29,
                  option_size: int = 26, two_col: bool = True) -> None:
    image, draw = new_page(1080, 1420, course, tag)
    y = 190
    y = draw_stem(draw, 64, y, 1, stem, size=size)
    y += 26
    y = draw_options(draw, 64, y, options, size=option_size, mono=mono, two_col=two_col)
    y = max(y + 50, 1080)
    y = draw_answer(draw, 64, y, student)
    draw.text((64, y + 18), "（只记录题干与作答，不含标准答案）",
              font=font(FONT_REG, 19), fill=MUTED)
    finish_page(image, draw, "第 1 页，共 1 页")
    image.save(path, "PNG", optimize=True)


def render_multi(path: Path) -> None:
    image, draw = new_page(1080, 1860, "概率论与数理统计 / 数据库系统原理 / 编译原理",
                           "三题合页")
    blocks = [
        ("概率论与数理统计", "同时掷两枚均匀的骰子，点数之和为 7 的概率是（　）。",
         ["1/6", "1/9", "1/12", "1/18"], "B"),
        ("数据库系统原理", "事务的 ACID 特性中，保证“要么全部执行、要么全部不执行”的是（　）。",
         ["原子性", "一致性", "隔离性", "持久性"], "B"),
        ("编译原理", "词法分析阶段的主要任务是（　）。",
         ["识别单词符号", "构建语法树", "生成目标代码", "分配寄存器"], "C"),
    ]
    y = 186
    for i, (course, stem, options, student) in enumerate(blocks, start=1):
        draw.text((64, y), f"{i:02d}  {course}", font=font(FONT_BOLD, 21), fill=MUTED)
        y += 34
        y = draw_stem(draw, 64, y, i, stem, size=27)
        y += 16
        y = draw_options(draw, 64, y, options, size=24, two_col=True)
        y += 18
        y = draw_answer(draw, 64, y, student, note="（未订正）")
        y += 34
        if i < len(blocks):
            draw.line((64, y, 1016, y), fill=LINE, width=1)
            y += 28
    finish_page(image, draw, "第 1 页，共 1 页")
    image.save(path, "PNG", optimize=True)


def render_schedule(path: Path) -> None:
    """生成一张可直接走“图片导入课表”的周课表。"""
    width, height = 1800, 1520
    image = Image.new("RGB", (width, height), "#F1F4FA")
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((36, 36, width - 36, height - 36), radius=26, fill="#FFFFFF")

    draw.text((90, 74), "2026 秋季学期 · 每周课表", font=font(FONT_BOLD, 52), fill="#14213D")
    draw.text((90, 148), "第 10 周（2026-11-02 ～ 11-08）· 虚构测试数据",
              font=font(FONT_REG, 26), fill=MUTED)

    x0, y0 = 90, 228
    time_w, day_w, header_h, row_h = 232, 286, 66, 142
    headers = ["时间", "周一", "周二", "周三", "周四", "周五"]
    table_w = time_w + day_w * 5
    draw.rounded_rectangle((x0, y0, x0 + table_w, y0 + header_h), radius=10, fill="#2F5FD0")
    draw.text((x0 + 22, y0 + 16), headers[0], font=font(FONT_BOLD, 28), fill="#FFFFFF")
    for i, day in enumerate(headers[1:]):
        cx = x0 + time_w + day_w * i + day_w // 2
        draw.text((cx - text_width(draw, day, font(FONT_BOLD, 28)) / 2, y0 + 16),
                  day, font=font(FONT_BOLD, 28), fill="#FFFFFF")

    rows = [
        ("08:00-09:40", ["数据库系统原理\nA201", "", "编译原理\nA401", "", "概率论与数理统计\nB202"]),
        ("10:00-11:40", ["", "概率论与数理统计\nB202", "", "马克思主义基本原理\nC101", "编译原理\nA401"]),
        ("14:00-15:40", ["软件工程导论\nA305", "大学英语（四）\n外语楼 302",
                          "数据库系统原理实验\nA201", "软件工程导论\n项目室", "大学英语（四）\n外语楼 302"]),
        ("19:00-21:00", ["自主复习"] * 5),
    ]
    for r, (time_text, cells) in enumerate(rows):
        ry = y0 + header_h + r * row_h
        fill = "#F7F9FF" if r % 2 == 0 else "#FFFFFF"
        draw.rectangle((x0, ry, x0 + table_w, ry + row_h), fill=fill)
        draw.text((x0 + 22, ry + 50), time_text, font=font(FONT_REG, 25), fill="#374151")
        for c, cell in enumerate(cells):
            cx = x0 + time_w + day_w * c
            if cell:
                lines = cell.split("\n")
                if len(lines) > 1:
                    draw.text((cx + 18, ry + 30), lines[0], font=font(FONT_BOLD, 25), fill="#1F2937")
                    draw.text((cx + 18, ry + 72), lines[1], font=font(FONT_REG, 21), fill=MUTED)
                else:
                    draw.text((cx + 18, ry + 50), lines[0], font=font(FONT_REG, 23), fill=MUTED)
        draw.line((x0, ry + row_h, x0 + table_w, ry + row_h), fill="#D9E1F2", width=2)
    for c in range(1, 6):
        lx = x0 + time_w + day_w * c
        draw.line((lx, y0 + header_h, lx, y0 + header_h + row_h * 4), fill="#D9E1F2", width=2)
    draw.line((x0 + time_w, y0 + header_h, x0 + time_w, y0 + header_h + row_h * 4),
              fill="#D9E1F2", width=2)

    exam_y = y0 + header_h + row_h * 4 + 64
    draw.text((90, exam_y), "考试安排（图片识别时请一并核对）",
              font=font(FONT_BOLD, 34), fill="#14213D")
    exam_header_y = exam_y + 62
    col_widths = [650, 470, 300]
    draw.rounded_rectangle((90, exam_header_y, 90 + sum(col_widths), exam_header_y + 58),
                           radius=8, fill="#2F5FD0")
    exam_headers = ["课程名称", "考试日期", "复习优先级"]
    ex = 112
    for label, col_w in zip(exam_headers, col_widths):
        draw.text((ex, exam_header_y + 14), label, font=font(FONT_BOLD, 26), fill="#FFFFFF")
        ex += col_w

    exams = [(c["courseName"], c["examDate"], c["priority"]) for c in COURSES]
    for i, (name, date, priority) in enumerate(exams):
        ey = exam_header_y + 58 + i * 58
        draw.rectangle((90, ey, 90 + sum(col_widths), ey + 58),
                       fill="#F7F9FF" if i % 2 == 0 else "#FFFFFF")
        ex = 112
        for value, col_w in zip((name, date, priority), col_widths):
            draw.text((ex, ey + 15), value, font=font(FONT_REG, 24), fill="#1F2937")
            ex += col_w
        draw.line((90, ey + 58, 90 + sum(col_widths), ey + 58), fill="#D9E1F2", width=1)

    draw.text((90, height - 82), "课程与日期均为虚构测试数据，不对应真实教务信息",
              font=font(FONT_REG, 21), fill=MUTED)
    image.save(path, "PNG", optimize=True)


def generate_images() -> None:
    IMG_DIR.mkdir(parents=True, exist_ok=True)
    render_single(
        IMG_DIR / "wrong_01_probability_bayes.png",
        "概率论与数理统计", "01",
        "某工厂甲、乙两条生产线分别生产 60% 和 40% 的产品，次品率分别为 2% 和 5%。"
        "从全部产品中任取一件，发现是次品，则它来自甲生产线的概率约为（　）。",
        ["0.375", "0.600", "0.625", "0.800"], "C",
    )
    render_single(
        IMG_DIR / "wrong_02_database_sql.png",
        "数据库系统原理", "02",
        "已知成绩表 score(student_id, course_id, score)。要查询平均分高于 80 分的课程号，"
        "下列 SQL 正确的是（　）。",
        [
            "SELECT course_id FROM score WHERE AVG(score)>80 GROUP BY course_id;",
            "SELECT course_id FROM score GROUP BY course_id HAVING AVG(score)>80;",
            "SELECT course_id FROM score GROUP BY course_id WHERE AVG(score)>80;",
            "SELECT course_id FROM score HAVING AVG(score)>80;",
        ], "A", mono=True, option_size=19, two_col=False,
    )
    render_single(
        IMG_DIR / "wrong_03_compiler_follow.png",
        "编译原理", "03",
        "已知文法：S → A a；A → B b | ε；B → c。则 FOLLOW(A) =（　）。",
        ["{ a }", "{ $, a }", "{ b }", "{ $, a, b }"], "A", size=31, option_size=28,
    )
    render_single(
        IMG_DIR / "wrong_04_software_uml.png",
        "软件工程导论", "04",
        "在 UML 用例图中，若用例 A 的行为必然包含用例 B 的行为，则 A 与 B 之间应使用（　）关系。",
        ["泛化", "包含（include）", "扩展（extend）", "依赖"], "C", size=30,
    )
    render_single(
        IMG_DIR / "wrong_05_english_clause.png",
        "大学英语（四）", "05",
        "Choose the correct word to complete the sentence: "
        "The book ______ I borrowed from the library is due next Monday.",
        ["who", "whom", "which", "whose"], "A", size=29,
    )
    render_single(
        IMG_DIR / "wrong_06_marxism_dialectics.png",
        "马克思主义基本原理", "06",
        "唯物辩证法认为，事物发展的根本原因在于（　）。",
        ["事物内部的矛盾性", "事物外部条件的推动", "人们主观意志的选择", "事物数量的增减"],
        "B", size=30,
    )
    render_multi(IMG_DIR / "wrong_07_multi_three_questions.png")
    render_schedule(OUT / "12-课表-图片.png")


# ---------------------------------------------------------------- 说明文件

REFERENCE = """# 错题参考答案与预期（测试用，不要上传这张说明）

> 图片只含题干和“我的答案”，**不含标准答案**。
> 本文件用于人工核对模型返回的知识点、答案和解析是否正确。
> 上传到 App 的只有 `错题/` 目录下的 7 张 PNG。

## 一、单题图片

| 图片 | 科目 | 学生答案 | 正确答案 | 预期知识点 / 诊断方向 |
|---|---|---|---|---|
| `wrong_01_probability_bayes.png` | 概率论与数理统计 | C | **A（0.375）** | 全概率公式与贝叶斯公式；把 P(甲) 与 P(甲\\|次) 混淆 |
| `wrong_02_database_sql.png` | 数据库系统原理 | A | **B** | SQL 分组过滤：`WHERE` 不能对聚合函数过滤，应使用 `HAVING` |
| `wrong_03_compiler_follow.png` | 编译原理 | A | **B（{ $, a }）** | FOLLOW 集计算；漏掉开始符号的结束符 `$` |
| `wrong_04_software_uml.png` | 软件工程导论 | C | **B** | 用例图 include 与 extend 的区别；把“必然包含”误判为扩展 |
| `wrong_05_english_clause.png` | 大学英语（四） | A | **C** | 定语从句关系代词；先行词是物，从句中作宾语，用 which |
| `wrong_06_marxism_dialectics.png` | 马克思主义基本原理 | B | **A** | 唯物辩证法：内因是事物发展的根本原因 |

## 二、三题合页

图片：`wrong_07_multi_three_questions.png`

预期识别出 **3 道题**，且题号、题干、选项完整：

| 题号 | 科目 | 学生答案 | 正确答案 | 预期知识点 |
|---|---|---|---|---|
| 1 | 概率论与数理统计 | B | **A（1/6）** | 古典概型；两枚骰子 36 个等可能结果，和为 7 有 6 种 |
| 2 | 数据库系统原理 | B | **A（原子性）** | 事务 ACID；原子性 = 全部执行或全部不执行 |
| 3 | 编译原理 | C | **A（识别单词符号）** | 词法分析的任务；语法树属于语法分析 |

## 三、验收要点

1. 单题图片应返回 1 道题；三题合页应返回 3 道题，不能只返回第一道。
2. 每道题应有完整题干、选项、正确答案和解析；缺选项或只剩知识点都算不合格。
3. 图片中没有写“错在哪里”，模型不应编造“你当时怎么错的”这类个人错因；
   可以根据作答给出知识点层面的错误类型。
4. 逐题选择“加入错题本”时，只应对勾选的题生效；三题合页只勾 2 道，错题本应恰好增加 2 道。
5. 同一张图重复分析不应重复入本；确认加入后再重进错题本核对数量。

## 四、图片生成方式

由 `tools/generate_final_test_data.py` 用 Pillow 生成，字体为系统微软雅黑 / 等线 / 楷体，
不含真实学生信息。需要改题时修改脚本顶部的渲染参数后重跑即可。
"""

README = """# 决赛联调测试数据（2026-11-05）

> 新生成的一组虚构数据，**不复用** `演示测试数据/` 里已有的
> 「数据结构 / 操作系统 / 计算机网络 / 高等数学」课程与旧 DDL 标题。
> 所有日期相对 **2026-11-05** 设置，导入后能算出有区分度的剩余天数。

---

## 一、文件清单（每份文件测一个点，内容不重复）

### 课程表

| 文件 | 格式 / 测试点 | 预期结果 |
|---|---|---|
| `01-课表-标准CSV.csv` | 中文表头 + UTF-8 BOM，6 门课 | 导入 6 门课程 |
| `02-课表-宽松格式.csv` | 别名表头；日期写成 `2026/11/19`、`11月24日`、`2026.11.27`、`2026年12月3日`；priority/status 留空 | 导入 5 门，空字段按剩余天数/学习时长自动推断 |
| `03-课表-无表头.csv` | 第 1 行就是数据，第 2 列是日期 | 导入 3 门（解析器按约定列序识别） |
| `04-课表-完整JSON.json` | `{"courses": [...]}`，6 门 | 导入 6 门 |
| `05-课表-粘贴用.txt` | 与 04 相同，走「粘贴导入」 | 导入 6 门 |

### 作业 DDL

| 文件 | 格式 / 测试点 | 预期结果 |
|---|---|---|
| `06-DDL-标准CSV.csv` | 中文表头 + BOM，10 条 | 导入 10 项 |
| `07-DDL-引号逗号.csv` | 标题含半角逗号、中文顿号、括号、破折号，引号包裹 | 导入 4 项，标题不被逗号切断 |
| `08-DDL-制表符.csv` | 制表符分隔 + BOM（Excel 直接复制） | 导入 5 项 |
| `09-DDL-完整JSON.json` | `{"ddls": [...]}`，10 条 | 导入 10 项 |
| `10-DDL-粘贴用.txt` | 与 09 相同，走「粘贴导入」 | 导入 10 项 |

### 组合与负样例

| 文件 | 用途 |
|---|---|
| `11-课程与DDL-合并JSON.json` | 同时含 `courses` 与 `ddls`，在「课程」类型导一次、切到「作业 DDL」再导一次，可一个文件覆盖两类 |
| `90-错误样例-日期待定.csv` | **不要用于正常导入**。第 2 行日期是「待定」、第 3 行是「下周三」，应提示第 2 行日期认不出来 |

### 错题图片

| 文件 | 科目 / 题数 | 学生答案 |
|---|---|---|
| `错题/wrong_01_probability_bayes.png` | 概率论 · 1 题 | C（正确 A） |
| `错题/wrong_02_database_sql.png` | 数据库 · 1 题 | A（正确 B） |
| `错题/wrong_03_compiler_follow.png` | 编译原理 · 1 题 | A（正确 B） |
| `错题/wrong_04_software_uml.png` | 软件工程 · 1 题 | C（正确 B） |
| `错题/wrong_05_english_clause.png` | 大学英语 · 1 题 | A（正确 C） |
| `错题/wrong_06_marxism_dialectics.png` | 马原 · 1 题 | B（正确 A） |
| `错题/wrong_07_multi_three_questions.png` | 三科合页 · **3 题** | 第 1/2/3 题分别 B/B/C |

> 正确答案、预期知识点和验收要点见 `错题/错题参考答案与预期.md`。
> **不要上传这份说明**，上传的只有 7 张 PNG。

---

## 二、导入前必须知道的两条规则

1. **导入是“替换”不是“合并”**：课程表导入会替换现有课程列表，DDL 导入会替换现有 DDL 列表。
   所以每类只选一个文件；不要连续导入两个课程文件指望叠加。
2. **同一个合并 JSON 分两次导**：先选「课程」标签导 `11-...json`，再切到「作业 DDL」导同一个文件。
   页面上的类型选择 / 标签页决定用哪个解析器。

---

## 三、在模拟器上导入课程 / DDL

文件已经由 `导入四个模拟器.ps1` 推到每台设备的：

```
/storage/Users/currentUser/Download/Zhixue20261105/
```

App 内路径：

1. 首页 → 课程与作业（课程导入页）。
2. 点「导入」标签 → 「导入课程表（JSON / CSV）」→ 在系统文件选择器里找
   `Download/Zhixue20261105/` → 选 `01-课表-标准CSV.csv`。
3. 看到「成功导入 6 门课程」后，切到「作业 DDL」→ 「导入作业DDL（JSON / CSV）」
   → 选 `06-DDL-标准CSV.csv` → 「成功导入 10 项作业」。
4. 返回学习计划页，确认任务带上新 DDL。

> 文件选择器里若看不到，先在文件管理器中打开一次 `Download/Zhixue20261105`；
> 仍看不到时改用「粘贴导入」：打开 `05-课表-粘贴用.txt` / `10-DDL-粘贴用.txt`
> 全选复制，选对类型后粘贴。

---

## 四、在模拟器上导入错题

图片已复制到上述 `Download/Zhixue20261105/`，并已用 `mediatool` 登记到系统相册。

App 内路径：

1. 首页 → 错题诊断（或「学习 → 错题本 → 拍照/相册」）。
2. 点「从相册选择」→ 找到 `Zhixue20261105` 相册或按文件名找 `wrong_01...png`。
3. 选一张 → 等待识别 → 核对题干/选项 → 勾选「加入错题本（可选）」→ 确认加入。
4. 三题合页那张用来测多题：应出现 3 道题，只勾选其中 2 道，确认后错题本只增加 2 道。

> 图片导入只是“把素材放进模拟器”；**识别和入本必须在 App 内确认**，
> 脚本不会替账号点“加入错题本”，也不会改后端数据。

---

## 五、一键导入四台模拟器

```powershell
powershell -ExecutionPolicy Bypass -File "演示测试数据\\决赛联调-20261105\\导入四个模拟器.ps1"
```

默认依次处理 Pura 90 → Mate X7 → MatePad Pro 13 → MateBook Pro：
没有在线设备时自动启动，导入并校验文件大小、相册登记，再关闭该模拟器。
结果写入 `导入结果.json`。

常用参数：

```powershell
# 只处理其中两台，且导入后不关闭
... 导入四个模拟器.ps1 -Names 'Pura 90','MatePad Pro 13' -KeepRunning

# 模拟器已经手动启动好了，跳过启动/停止
... 导入四个模拟器.ps1 -Names 'Pura 90' -SkipStart -SkipStop

# 只推文件，不登记相册
... 导入四个模拟器.ps1 -SkipGallery
```

---

## 六、负样例与错误提示

用 `90-错误样例-日期待定.csv` 走一次课程导入，应看到：

```
第 2 行的考试日期认不出来：「待定」。
支持的写法：2026-10-15、2026/10/15、2026年10月15日、10月15日。
```

这用于演示“错误处理给可读提示而不是崩溃”。演示完请重新导入 `01` 恢复正常数据。

---

## 七、重新生成

```powershell
python tools\\generate_final_test_data.py
```

脚本会覆盖本目录下的 CSV / JSON / TXT / PNG 和说明文件；
`导入结果.json` 由导入脚本生成，不在覆盖范围内。
日期固定为 2026-11 月，若在更晚的时间使用，请先改脚本顶部的 `COURSES` / `DDLS` 日期再重跑。
"""


def generate_docs() -> None:
    # README 允许在生成后手工补充（例如桌面路径、导入方式），重跑脚本不覆盖已有版本。
    readme = OUT / "README-使用说明.md"
    if not readme.exists():
        write_text(readme, README)
    write_text(IMG_DIR / "错题参考答案与预期.md", REFERENCE)


def main() -> None:
    generate_text_files()
    generate_images()
    generate_docs()
    print(f"generated: {OUT}")
    for path in sorted(OUT.rglob("*")):
        if path.is_file():
            print(f"  {path.relative_to(OUT)}  {path.stat().st_size} bytes")


if __name__ == "__main__":
    main()
