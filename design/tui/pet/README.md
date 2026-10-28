# 惠惠终端像素动画

`megumin-approved-poses.png` 是用户确认的六姿态设计稿。`megumin.json` 是终端直接读取的 64 × 80 调色板像素数据；运行时以半格字符保持比例绘制，无需图片协议或 GUI。

当前采用 8 色平涂版本，运行 `python tool/build_simple_megumin.py` 可重建终端原生像素数据。去掉渐变、纹理和粒子，保留待机、呼吸、眨眼、自我介绍、举杖咏唱、施法和力竭动作，以及原有点击交互和台词。窄窗口自动缩小；输入框或命令菜单展开时以实际剩余高度布局，禁止覆盖输入区域。

`megumin-detailed.json` 保留较复杂的版本；`tool/import_megumin_sprite.py` 可由确认稿重建该版本，勿覆盖当前简化版。

`megumin-legacy.json` 保留替换前的数据供回溯。
