"""从系统的 Noto Sans SC 可变字体生成仓库内使用的小体积静态子集。

为什么：封面/预览图里的中文/拉丁文字要用**开源可商用**字体，且仓库里要自带一份
可复现的字体文件（不在运行时依赖系统字体）。Noto Sans SC 是 SIL OFL 1.1
（copyright 2014-2021 Adobe，Reserved Font Name 'Source'），允许子集化与再分发，
但必须保留许可证与版权声明（见 assets/fonts/OFL.txt）。

源字体默认取 Windows 自带的 NotoSansSC-VF.ttf，可用环境变量 NOTO_SANS_SC_VF 覆盖。
生成：
  assets/fonts/NotoSansSC-Regular-subset.ttf
  assets/fonts/NotoSansSC-Bold-subset.ttf
"""
import os
import sys

from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from fontTools.subset import Options, Subsetter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "assets", "fonts")
SOURCE = os.environ.get("NOTO_SANS_SC_VF", r"C:\Windows\Fonts\NotoSansSC-VF.ttf")

# 封面 + 尺寸预览图用到的全部文字（改了文案记得同步这里）
CHARSET = (
    "dsh-floating-ball"
    "DSH 悬浮球：任务跑完没有，一眼就知道"
    "Windows 置顶 · 会话状态 · 面板内直接回话"
    "非官方 · 社区插件"
    "浅色背景 深色背景 px"
    "0123456789"
    "abcdefghijklmnopqrstuvwxyz"
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "-.,:;()/\\+'\"!?&%#@*=_[]{}<>|~`^$"
    "，。：；、（）【】《》——…·"
)


def rename_subset(font: TTFont) -> None:
    """OFL 要求：修改版不得使用 Reserved Font Name。这里统一改名为
    'Noto Sans SC Media Subset'，并保留许可证与版权 name 记录。"""
    new_name = 'Noto Sans SC Media Subset'
    for record in font['name'].names:
        if record.nameID in (1, 4, 6, 16, 17):
            try:
                record.string = new_name
            except Exception:
                record.string = new_name.encode('utf-16-be')
    print('renamed subset font family to:', new_name)


def build(weight: int, suffix: str) -> str:
    font = TTFont(SOURCE)
    font = instantiateVariableFont(font, {"wght": weight}, updateFontNames=True)
    options = Options()
    options.layout_features = ["*"]
    options.name_IDs = ["*"]
    options.name_legacy = True
    options.notdef_outline = True
    subsetter = Subsetter(options=options)
    subsetter.populate(text=CHARSET)
    subsetter.subset(font)
    rename_subset(font)
    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(OUT_DIR, f"NotoSansSC-{suffix}-subset.ttf")
    font.save(out)
    print(f"{out}  {os.path.getsize(out)} bytes")
    return out


if __name__ == "__main__":
    if not os.path.exists(SOURCE):
        print(f"source font not found: {SOURCE}", file=sys.stderr)
        raise SystemExit(1)
    build(400, "Regular")
    build(700, "Bold")
