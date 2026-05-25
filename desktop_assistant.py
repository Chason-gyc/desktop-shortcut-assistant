import os
import shutil
import subprocess
import sys
import tkinter as tk
from pathlib import Path
from tkinter import messagebox


APP_NAME = "桌面助手"
APP_WIDTH = 280
APP_HEIGHT = 430
MARGIN_LEFT = 10
MARGIN_BOTTOM = 42
SHORTCUT_EXTENSIONS = {".lnk", ".url", ".appref-ms"}


BASE_DIR = Path(__file__).resolve().parent
SHORTCUTS_DIR = BASE_DIR / "shortcuts"
SHORTCUTS_DIR.mkdir(exist_ok=True)


def desktop_dir() -> Path:
    return Path.home() / "Desktop"


def public_desktop_dir() -> Path:
    return Path(os.environ.get("PUBLIC", r"C:\Users\Public")) / "Desktop"


def display_name(path: Path) -> str:
    return path.stem if path.suffix.lower() in SHORTCUT_EXTENSIONS else path.name


def unique_destination(target_dir: Path, name: str) -> Path:
    candidate = target_dir / name
    if not candidate.exists():
        return candidate

    stem = candidate.stem
    suffix = candidate.suffix
    index = 2
    while True:
        next_candidate = target_dir / f"{stem} ({index}){suffix}"
        if not next_candidate.exists():
            return next_candidate
        index += 1


class DesktopAssistant(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title(APP_NAME)
        self.resizable(False, True)
        self.attributes("-topmost", True)
        self.configure(bg="#f4f6f8")

        self.protocol("WM_DELETE_WINDOW", self.withdraw)

        self.search_var = tk.StringVar()
        self.items_frame: tk.Frame | None = None
        self.status_var = tk.StringVar()

        self._build_ui()
        self._place_bottom_left()
        self.refresh()

    def _build_ui(self) -> None:
        header = tk.Frame(self, bg="#1f2937", padx=12, pady=10)
        header.pack(fill="x")

        title = tk.Label(
            header,
            text=APP_NAME,
            font=("Microsoft YaHei UI", 12, "bold"),
            fg="#ffffff",
            bg="#1f2937",
        )
        title.pack(side="left")

        close_btn = tk.Button(
            header,
            text="隐藏",
            command=self.withdraw,
            relief="flat",
            bg="#374151",
            fg="#ffffff",
            activebackground="#4b5563",
            activeforeground="#ffffff",
            cursor="hand2",
        )
        close_btn.pack(side="right")

        controls = tk.Frame(self, bg="#f4f6f8", padx=10, pady=10)
        controls.pack(fill="x")

        search = tk.Entry(
            controls,
            textvariable=self.search_var,
            font=("Microsoft YaHei UI", 10),
            relief="solid",
            bd=1,
        )
        search.pack(fill="x", ipady=5)
        search.bind("<KeyRelease>", lambda _event: self.refresh())

        actions = tk.Frame(controls, bg="#f4f6f8")
        actions.pack(fill="x", pady=(8, 0))

        collect_btn = self._button(actions, "收纳桌面快捷方式", self.collect_desktop_shortcuts)
        collect_btn.pack(side="left", fill="x", expand=True, padx=(0, 4))

        refresh_btn = self._button(actions, "刷新", self.refresh)
        refresh_btn.pack(side="left", fill="x", expand=True, padx=(4, 0))

        list_shell = tk.Frame(self, bg="#e5e7eb", padx=1, pady=1)
        list_shell.pack(fill="both", expand=True, padx=10, pady=(0, 8))

        canvas = tk.Canvas(list_shell, bg="#ffffff", highlightthickness=0, height=260)
        scrollbar = tk.Scrollbar(list_shell, orient="vertical", command=canvas.yview)
        self.items_frame = tk.Frame(canvas, bg="#ffffff")
        self.items_frame.bind(
            "<Configure>",
            lambda _event: canvas.configure(scrollregion=canvas.bbox("all")),
        )
        canvas.create_window((0, 0), window=self.items_frame, anchor="nw", width=APP_WIDTH - 34)
        canvas.configure(yscrollcommand=scrollbar.set)
        canvas.pack(side="left", fill="both", expand=True)
        scrollbar.pack(side="right", fill="y")

        footer = tk.Frame(self, bg="#f4f6f8", padx=10, pady=(0, 10))
        footer.pack(fill="x")

        restore_btn = self._button(footer, "恢复全部到桌面", self.restore_all)
        restore_btn.pack(fill="x")

        status = tk.Label(
            footer,
            textvariable=self.status_var,
            anchor="w",
            bg="#f4f6f8",
            fg="#4b5563",
            font=("Microsoft YaHei UI", 9),
        )
        status.pack(fill="x", pady=(6, 0))

    def _button(self, parent: tk.Widget, text: str, command) -> tk.Button:
        return tk.Button(
            parent,
            text=text,
            command=command,
            relief="flat",
            bg="#2563eb",
            fg="#ffffff",
            activebackground="#1d4ed8",
            activeforeground="#ffffff",
            cursor="hand2",
            font=("Microsoft YaHei UI", 9),
            padx=8,
            pady=6,
        )

    def _place_bottom_left(self) -> None:
        self.update_idletasks()
        screen_height = self.winfo_screenheight()
        y = max(0, screen_height - APP_HEIGHT - MARGIN_BOTTOM)
        self.geometry(f"{APP_WIDTH}x{APP_HEIGHT}+{MARGIN_LEFT}+{y}")

    def shortcut_files(self) -> list[Path]:
        return sorted(
            [
                item
                for item in SHORTCUTS_DIR.iterdir()
                if item.is_file() and item.suffix.lower() in SHORTCUT_EXTENSIONS
            ],
            key=lambda item: display_name(item).lower(),
        )

    def refresh(self) -> None:
        if self.items_frame is None:
            return

        for child in self.items_frame.winfo_children():
            child.destroy()

        query = self.search_var.get().strip().lower()
        files = [item for item in self.shortcut_files() if query in display_name(item).lower()]

        if not files:
            empty = tk.Label(
                self.items_frame,
                text="暂无快捷方式，点击“收纳桌面快捷方式”。",
                bg="#ffffff",
                fg="#6b7280",
                wraplength=APP_WIDTH - 50,
                justify="left",
                font=("Microsoft YaHei UI", 9),
                padx=10,
                pady=18,
            )
            empty.pack(fill="x")
        else:
            for item in files:
                self._add_shortcut_row(item)

        total = len(self.shortcut_files())
        self.status_var.set(f"已收纳 {total} 个快捷方式")

    def _add_shortcut_row(self, path: Path) -> None:
        row = tk.Frame(self.items_frame, bg="#ffffff", padx=8, pady=5)
        row.pack(fill="x")

        open_btn = tk.Button(
            row,
            text=display_name(path),
            anchor="w",
            command=lambda p=path: self.open_shortcut(p),
            relief="flat",
            bg="#ffffff",
            fg="#111827",
            activebackground="#eef2ff",
            activeforeground="#111827",
            cursor="hand2",
            font=("Microsoft YaHei UI", 10),
            padx=4,
            pady=5,
        )
        open_btn.pack(side="left", fill="x", expand=True)

        restore_btn = tk.Button(
            row,
            text="还原",
            command=lambda p=path: self.restore_one(p),
            relief="flat",
            bg="#f3f4f6",
            fg="#374151",
            activebackground="#e5e7eb",
            activeforeground="#111827",
            cursor="hand2",
            font=("Microsoft YaHei UI", 8),
            padx=6,
            pady=3,
        )
        restore_btn.pack(side="right", padx=(6, 0))

    def collect_desktop_shortcuts(self) -> None:
        moved = 0
        for source_dir in [desktop_dir(), public_desktop_dir()]:
            if not source_dir.exists():
                continue
            for item in source_dir.iterdir():
                if item.name.lower() == "desktop.ini":
                    continue
                if item.is_file() and item.suffix.lower() in SHORTCUT_EXTENSIONS:
                    destination = unique_destination(SHORTCUTS_DIR, item.name)
                    try:
                        shutil.move(str(item), str(destination))
                        moved += 1
                    except OSError as exc:
                        messagebox.showwarning(APP_NAME, f"无法移动：{item.name}\n{exc}")

        self.refresh()
        if moved == 0:
            messagebox.showinfo(APP_NAME, "桌面上没有发现新的快捷方式。")
        else:
            messagebox.showinfo(APP_NAME, f"已收纳 {moved} 个桌面快捷方式。")

    def open_shortcut(self, path: Path) -> None:
        if not path.exists():
            messagebox.showerror(APP_NAME, "这个快捷方式已经不存在。")
            self.refresh()
            return

        try:
            os.startfile(path)  # type: ignore[attr-defined]
        except OSError:
            try:
                subprocess.Popen(["cmd", "/c", "start", "", str(path)], shell=False)
            except OSError as exc:
                messagebox.showerror(APP_NAME, f"无法打开：{display_name(path)}\n{exc}")

    def restore_one(self, path: Path) -> None:
        if not path.exists():
            self.refresh()
            return
        destination = unique_destination(desktop_dir(), path.name)
        try:
            shutil.move(str(path), str(destination))
        except OSError as exc:
            messagebox.showerror(APP_NAME, f"无法还原：{path.name}\n{exc}")
        self.refresh()

    def restore_all(self) -> None:
        files = self.shortcut_files()
        if not files:
            messagebox.showinfo(APP_NAME, "没有需要恢复的快捷方式。")
            return
        if not messagebox.askyesno(APP_NAME, f"确定把 {len(files)} 个快捷方式恢复到桌面吗？"):
            return

        restored = 0
        for item in files:
            destination = unique_destination(desktop_dir(), item.name)
            try:
                shutil.move(str(item), str(destination))
                restored += 1
            except OSError as exc:
                messagebox.showwarning(APP_NAME, f"无法还原：{item.name}\n{exc}")
        self.refresh()
        messagebox.showinfo(APP_NAME, f"已恢复 {restored} 个快捷方式。")


def main() -> int:
    if sys.platform != "win32":
        print("这个小助手是为 Windows 桌面设计的。")
        return 1
    app = DesktopAssistant()
    app.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
