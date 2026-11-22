"""The Webb half of the split screen: weic2211a (large, 4685 px) cropped 8:9 to the Cartwheel alone,
without G1 and G2. The same crop is the map photo-match.py reads. usage: panel.py <weic2211a.jpg> <out dir>"""
import sys
from PIL import Image
im = Image.open(sys.argv[1])
crop = im.crop((1647, 697, 4392, 3785))
crop.save(f"{sys.argv[2]}/cartwheel-crop.jpg", quality=95)
crop.resize((1920, 2160), Image.LANCZOS).save(f"{sys.argv[2]}/panel-webb.png")
