# UV-1780 / UVProbe 公开离线部署包

完整安装包已按所有者要求公开，下载不需要 GitHub 登录或 token。

[下载部署包 2.70.2](https://github.com/C12isme945/uv1780-packages/releases/tag/v2.70.2) · [一行安装入口与说明](https://github.com/C12isme945/uv1780-installer)

适用于 Intel/AMD Windows 10/11。运行库与驱动已包含，复制到目标电脑后可以完全离线安装和使用。默认预装软件，不要求仪器在线；实际连接和测量需在 UVProbe 中确认。

一行安装（Windows PowerShell）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://cdn.jsdelivr.net/gh/C12isme945/uv1780-installer@v2.70.2.2/install.ps1 | iex"
```

大陆直连镜像尚未提供，脚本支持指定 HTTPS 下载源和本地文件。42 项包回归检查及 148 项原生组件加载已通过；全新 Windows 实装验收尚未完成。

src 目录保留部署脚本快照；源软件与第三方构建输入不在 Git 源码树内，目标电脑安装请使用 Release 中的 EXE。
