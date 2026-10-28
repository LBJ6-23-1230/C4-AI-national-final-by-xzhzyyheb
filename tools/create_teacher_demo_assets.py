"""Create deterministic, fictional rehearsal inputs for the 2026-10-28 demo."""
import csv
import hashlib
import io
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "演示测试数据/指导老师预演-20261028"
FONT = "C:/Windows/Fonts/msyh.ttc"
BOLD = "C:/Windows/Fonts/msyhbd.ttc"
INK, MUTED, BLUE = "#14243C", "#53657D", "#2457CA"


def text(draw, xy, value, size=32, fill=INK, bold=False):
    draw.text(xy, value, font=ImageFont.truetype(BOLD if bold else FONT, size), fill=fill)


def wrap(draw, value, width, size):
    font = ImageFont.truetype(FONT, size)
    lines, current = [], ""
    for char in value:
        if draw.textlength(current + char, font=font) > width:
            lines.append(current)
            current = char
        else:
            current += char
    if current:
        lines.append(current)
    return lines


def canvas(title, subtitle, height=1500):
    im = Image.new("RGB", (1800, height), "#F4F7FC")
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((55, 45, 1745, height-45), radius=26, fill="white")
    text(d, (105, 90), title, 53, bold=True)
    text(d, (105, 170), subtitle, 27, MUTED)
    return im, d


def table(draw, xy, widths, headers, rows, row_height=105):
    x, y = xy
    total = sum(widths)
    draw.rounded_rectangle((x, y, x+total, y+70), radius=12, fill=BLUE)
    cursor = x
    for width, header in zip(widths, headers):
        text(draw, (cursor+18, y+17), header, 27, "white", True)
        cursor += width
    for i, row in enumerate(rows):
        top = y+70+i*row_height
        draw.rectangle((x, top, x+total, top+row_height), fill="#F0F5FD" if i % 2 == 0 else "#FFFFFF")
        cursor = x
        for width, value in zip(widths, row):
            lines = str(value).split("\n")
            for j, line in enumerate(lines):
                text(draw, (cursor+18, top+18+j*37), line, 27)
            cursor += width
    return y+70+len(rows)*row_height


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")


def write_csv(path, headers, rows):
    with path.open("w", newline="", encoding="utf-8-sig") as f:
        writer = csv.writer(f)
        writer.writerow(headers)
        writer.writerows(rows)


COURSES_A = [
    {"courseName": "数据结构", "examDate": "2026-11-09", "priority": "高", "studyHours": 1, "status": "二叉树遍历待练习"},
    {"courseName": "计算机网络", "examDate": "2026-11-11", "priority": "中", "studyHours": 2, "status": "可靠传输待复习"},
    {"courseName": "操作系统", "examDate": "2026-11-13", "priority": "中", "studyHours": 0, "status": "进程调度待复习"},
]
COURSES_B = [
    {"courseName": "数据结构", "examDate": "2026-11-09", "priority": "高", "studyHours": 3, "status": "二叉树基础待测评"},
    {"courseName": "计算机网络", "examDate": "2026-11-11", "priority": "中", "studyHours": 1, "status": "TCP基础待练习"},
    {"courseName": "线性代数", "examDate": "2026-11-12", "priority": "中", "studyHours": 1, "status": "矩阵运算待复习"},
]
DDLS_A = [
    {"courseName": "数据结构", "title": "二叉树遍历实验报告", "dueDate": "2026-10-29", "priority": "高", "estimatedMinutes": 45},
    {"courseName": "计算机网络", "title": "TCP三次握手实验", "dueDate": "2026-10-30", "priority": "高", "estimatedMinutes": 60},
    {"courseName": "操作系统", "title": "进程调度比较题", "dueDate": "2026-11-02", "priority": "中", "estimatedMinutes": 40},
    {"courseName": "数据结构", "title": "图的广度优先遍历练习", "dueDate": "2026-11-04", "priority": "中", "estimatedMinutes": 30},
]
DDLS_B = [
    {"courseName": "数据结构", "title": "遍历序列与树结构练习", "dueDate": "2026-10-30", "priority": "高", "estimatedMinutes": 40},
    {"courseName": "计算机网络", "title": "可靠传输机制小结", "dueDate": "2026-11-01", "priority": "中", "estimatedMinutes": 45},
    {"courseName": "线性代数", "title": "矩阵乘法课后练习", "dueDate": "2026-11-03", "priority": "中", "estimatedMinutes": 35},
]


def schedule(account, name, courses, file):
    im, d = canvas(f"{name}的每周课表", "2026秋季学期 · 第9周（10月26日 - 11月1日） · 虚构演示数据", 1510)
    rows = [
        ["08:00-09:40", "数据结构\n教学楼 A201", "自主学习", "数据结构\n教学楼 A201", "自主学习", "计算机网络\n教学楼 B302"],
        ["10:00-11:40", "自主学习", "计算机网络\n教学楼 B302", "自主学习", f"{courses[2]['courseName']}\n教学楼 A303", "自主学习"],
        ["14:00-15:40", f"{courses[2]['courseName']}\n教学楼 A303", "自主学习", "实验课\n数据结构", "自主学习", f"实验课\n{courses[2]['courseName']}"],
        ["19:00-21:00", "自主复习", "自主复习", "自主复习", "自主复习", "自主复习"],
    ]
    table(d, (105, 245), [230, 270, 270, 270, 270, 270], ["时间", "周一", "周二", "周三", "周四", "周五"], rows, 125)
    text(d, (105, 880), "考试安排（图片识别时请一并核对）", 36, bold=True)
    table(d, (105, 950), [480, 400, 700], ["课程名称", "考试日期", "复习优先级"],
          [[c['courseName'], c['examDate'], c['priority']] for c in courses], 92)
    text(d, (105, 1350), f"账号 {account} · 课程与日期均为演示样例，不代表真实教务信息", 25, MUTED)
    im.save(file)


def deadlines(ddls, file):
    im, d = canvas("本周作业与截止日期", "2026年10月28日展示用 · 账号A 林知远 · 虚构演示数据", 1330)
    rows = [[r['courseName'], r['title'], r['dueDate'], r['priority'], str(r['estimatedMinutes'])+"分钟"] for r in ddls]
    table(d, (105, 255), [270, 550, 330, 170, 260], ["课程", "作业标题", "截止日期", "优先级", "预计用时"], rows, 130)
    text(d, (105, 920), "导入方式", 36, bold=True)
    text(d, (105, 990), "在「课程与作业」切换到作业，选择 03_A_DDL.csv。", 31)
    text(d, (105, 1050), "也可导入 JSON，或复制 04_A_DDL.json 中的内容。", 31)
    text(d, (105, 1160), "这张图片用于展示与核对；作业文件导入使用 CSV / JSON。", 26, MUTED)
    im.save(file)


def question(file):
    im, d = canvas("数据结构 · 二叉树遍历练习", "单题清晰图片 · 虚构题目 · 请先解题，再根据学生作答判断错误原因", 1640)
    text(d, (110, 265), "第1题：写出下面二叉树的前序遍历序列。", 40, bold=True)
    positions = {'A': (900, 470), 'B': (575, 710), 'C': (1225, 710), 'D': (405, 950), 'E': (745, 950), 'F': (1395, 950)}
    for parent, child in [('A','B'),('A','C'),('B','D'),('B','E'),('C','F')]:
        d.line((*positions[parent], *positions[child]), fill="#516989", width=7)
    for label, (x,y) in positions.items():
        d.ellipse((x-65,y-65,x+65,y+65), fill="#ECF3FF", outline=BLUE, width=5)
        text(d, (x-23,y-38), label, 57, BLUE, True)
    text(d, (110, 1130), "作答区：______________________________________", 37)
    text(d, (110, 1240), "请说明：访问根结点、左子树和右子树的顺序。", 34)
    text(d, (110, 1380), "提示：若暂未提供学生作答，只能解释题目，不能推断个人错因。", 27, MUTED)
    im.save(file)


LECTURE = """数据结构讲义：二叉树遍历与队列
本材料为知学Mate教学演示编写，不对应真实学校试卷。

第一节 二叉树的基本结构
二叉树的每个结点最多有两个孩子，分别称为左孩子和右孩子。左右子树有顺序，不能随意交换。树的根结点没有父结点；没有孩子的结点是叶结点。空树可以作为递归的终止条件。
示例树：A为根；A的左孩子为B，右孩子为C；B的左孩子为D，右孩子为E；C没有左孩子，右孩子为F。D、E、F均为叶结点。

第二节 前序遍历
前序遍历的规则是先访问根结点，再前序遍历左子树，最后前序遍历右子树，简称根-左-右。每次递归调用都对当前子树重复同一个规则，不能只对整棵树执行一次。
对于上述示例树，先访问A，再处理以B为根的子树得到B、D、E，最后处理以C为根的子树得到C、F，所以完整序列为A、B、D、E、C、F。
递归伪代码：若当前结点为空则返回；访问当前结点；递归处理左孩子；递归处理右孩子。

第三节 中序遍历
中序遍历的规则是先中序遍历左子树，再访问根结点，最后中序遍历右子树，简称左-根-右。示例树的中序序列为D、B、E、A、C、F。它与前序的差别在于访问根的时机。
对任意二叉树，中序序列不一定递增；只有满足左子树键值小于根、右子树键值大于根等条件的二叉搜索树，其中序序列才按键值顺序排列。

第四节 后序遍历
后序遍历先处理左子树，再处理右子树，最后访问根，简称左-右-根。示例树的后序序列是D、E、B、F、C、A。后序适合先处理孩子再处理父结点的情形，例如递归释放树的结点。
三种深度优先遍历都只访问每个结点一次，时间复杂度为O(n)。递归辅助空间取决于树高h，为O(h)；退化为链时，最坏可到O(n)。

第五节 层序遍历与队列
层序遍历从上到下逐层访问，每层从左到右。示例树的层序序列是A、B、C、D、E、F。
一种实现方法使用先进先出的队列：非空根结点入队；队列非空时取出队首并访问；若左孩子非空则入队；若右孩子非空则入队。队列保证较早发现的结点先被访问，因而不会先深入某个分支。
栈与队列的访问顺序不同。栈是后进先出，常用于实现深度优先遍历；队列是先进先出，常用于层序遍历和广度优先搜索。把队列误换成栈，通常会破坏按层访问的顺序。

第六节 从证据分析常见错误
如果学生在第1题给出D、B、E、A、C、F，那么答案与示例树的中序序列一致，可能混淆了前序和中序，应让学生说明根的访问时机并通过新题确认。仅有树的图片，没有学生答案，不能断言学生存在这种错误。
如果学生序列缺失结点，应先核对树结构和作答过程；如果交换了左右子树顺序，应核对是否理解有序性。学习诊断要依据实际作答，不能仅凭课程名给个人贴标签。
"""

NETWORK = """计算机网络讲义：TCP连接与可靠传输
本材料为虚构教学样例。

TCP为应用提供面向连接的可靠字节流服务。字节流意味着应用写入的消息边界不会被TCP直接保留，接收方需要自行确定应用层消息格式。
建立连接通常使用三次握手。客户端发送SYN报文并选择初始序列号x；服务端返回SYN与ACK，确认号为x+1，并选择初始序列号y；客户端发送ACK确认号y+1。SYN本身占用一个序列号。
三次握手使双方交换初始序列号，并让双方确认发送和接收能力。不能简单宣称两次交换已经使所有双方状态完全相同。
TCP的序列号按字节编号，确认号通常表示接收方期望下一个收到的字节编号。累计确认表示某个确认号以前的字节已连续收到。
可靠传输依靠校验、序列号、确认、重传等机制。丢失的数据段可因超时等条件而触发重传，发送方不会把应用数据直接当作已到达。
流量控制根据接收窗口限制发送方，避免接收方缓冲区被压垮；拥塞控制根据网络状况调节拥塞窗口，避免过度占用网络。两者解决的问题不同。
实例：初始序列号100的SYN被确认后，首个数据字节序号为101。若连续收到从101开始的100个字节，期望的下一个字节序号为201。
练习时请区分SYN占用序列号、应用数据占用的字节数、确认号所表达的下一个期望字节。不要把数据段个数等同于字节数。
"""


def main():
    images = OUT / "01-图片"
    imports = OUT / "02-课程与DDL"
    docs = OUT / "03-上传讲义"
    for folder in (images, imports, docs):
        folder.mkdir(parents=True, exist_ok=True)
    for account, name, courses, ddls in [('A','林知远',COURSES_A,DDLS_A),('B','苏念',COURSES_B,DDLS_B)]:
        schedule(account, name, courses, images/f"01_{account}_schedule.png")
        write_csv(imports/f"01_{account}_courses.csv", ['课程名称','考试日期','优先级','学习时长','状态'],
                  [[c[k] for k in ('courseName','examDate','priority','studyHours','status')] for c in courses])
        write_json(imports/f"02_{account}_courses.json", {"courses":courses})
        write_csv(imports/f"03_{account}_DDL.csv", ['课程名称','作业标题','截止日期','优先级','预计时长'],
                  [[r[k] for k in ('courseName','title','dueDate','priority','estimatedMinutes')] for r in ddls])
        write_json(imports/f"04_{account}_DDL.json", {"ddls":ddls})
    deadlines(DDLS_A, images/'02_A_DDL_preview.png')
    question(images/'03_binary_tree_question.png')
    (docs/'05_binary_tree_notes.txt').write_text(LECTURE, encoding='utf-8')
    (docs/'06_TCP_notes.txt').write_text(NETWORK, encoding='utf-8')
    manifest=[]
    for p in sorted(OUT.rglob('*')):
        if p.is_file() and p.name != '素材清单.json':
            manifest.append({'file':str(p.relative_to(OUT)),'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
    write_json(OUT/'素材清单.json', {'date':'2026-10-28','fictional':True,'files':manifest})
    print(f'Created {len(manifest)} assets in {OUT}')


if __name__ == '__main__':
    main()
