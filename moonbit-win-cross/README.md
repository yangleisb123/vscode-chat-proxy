# MoonBit → Windows x64 交叉编译包（在 Linux 上完成）

`moonbit-demo.exe` 是**完全在这台 Linux 机器（银河麒麟 V10，x86-64）上编译出来的 Windows 原生可执行文件**，
不是 wasm、不是脚本包装，是真正的 PE32+ 机器码，双击即可在 Windows 上运行。

## 验证结果（wine64 实测）

```
> moonbit-demo.exe
Hello from MoonBit — 这份 exe 是在 Linux 上交叉编译的！
fib(20..29) 之和 = 1335323
fib(35) = 9227465
doubled = 2 4 6 8 10
```

- 格式：`PE32+ executable (console) x86-64, for MS Windows`
- 体积：约 384 KB
- 依赖：仅 `KERNEL32.dll` 和 `msvcrt.dll`（Windows 自带系统库，无需安装任何运行时）
- 中文 UTF-8 输出、递归、循环、数组高阶函数均正常

## 原理（三步）

1. **MoonBit 新原生后端直接生成 Windows 对象文件**
   `moonc link-core -target x86_64-pc-windows-msvc` 把 `.core` 中间表示编译成
   Intel amd64 COFF 对象（MoonBit 0.1.20261120 已支持 4 个目标三元组）。
2. **用 mingw-w64 交叉编译 MoonBit 运行时 C 源码**
   工具链自带运行时源码（`~/.moon/lib/runtime/*.c`，原生支持 `_WIN32`/MinGW）。
   本 demo 只需 `runtime.c env.c utf.c backtrace.c` 四个文件；
   默认使用系统 malloc 分配器，不需要 mimalloc。
3. **静态链接**
   `x86_64-w64-mingw32-gcc -static` 把对象文件链成 exe，
   顺带用 objcopy 去掉 MSVC 专用的 `.drectve` 段。

## 复现

```bash
# 依赖：moon 工具链 + gcc-mingw-w64-x86-64（Ubuntu/麒麟: apt install gcc-mingw-w64-x86-64）
./build-win.sh <moon项目目录> <输出.exe>
# 例如本项目 demo（源码见 demo-main.mbt，放到项目 cmd/main/main.mbt）：
./build-win.sh ~/my-moonbit-app app.exe
```

## 已知限制（重要）

- **非官方工作流**：`moon build` 目前没有交叉编译参数，这是手动拼
  `moonc link-core` + mingw 的方案；官方一站式交叉编译尚未发布。
- **运行时按需裁剪**：demo 只链了 4 个运行时文件。若程序用到
  异步/文件/网络/进程等能力，需要补编对应源码
  （`io_windows.c`、`iocp.c`、`fs.c`、`socket.c`、`process.c`、`schannel.c` 等），
  并可能引入额外系统库（如 ws2_32、bcrypt）。
- **ABI 组合未经官方验证**：moonc 产出的是 MSVC ABI 目标对象，这里用 mingw
  链接。x64 调用约定一致，demo 实测可用，但复杂程序（SEH、TLS、对齐敏感结构）
  不保证无坑；官方 Windows 路线是 MSVC。
- **验证环境是 wine 5.0**，未在真实 Windows 上跑过；理论上只依赖系统 DLL，
  Win10/11 x64 应可直接运行。
- 分配器为系统 malloc（非 mimalloc），性能特征与官方 native 产物略有差异。

## 环境

- OS：银河麒麟桌面 V10 SP1（Linux x86-64）
- moon 0.1.20261120 / 新原生后端（MOONBIT_NEW_NATIVE=1）
- x86_64-w64-mingw32-gcc 9.3.0
- wine64-stable 5.0（仅用于验证）
