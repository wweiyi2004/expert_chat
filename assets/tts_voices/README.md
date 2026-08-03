# 自制音色样本（动漫风原型）

这些短音频由 **Microsoft Edge 在线神经网络 TTS**（`edge-tts`）生成，用于：

1. 可选的 MiMo `voiceclone` 种子样本  
2. 本地试听 / 打包资源  

它们是**角色原型**（元气少女、傲娇、清冷少年等），**不是**任何正版动漫角色的原声扒取，避免版权风险。

生成命令示例：

```bash
edge-tts --voice zh-CN-XiaoyiNeural --text "……" --write-media genki_girl.mp3
```
