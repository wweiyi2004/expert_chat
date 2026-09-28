"""Disposable foreground window for the opt-in Windows desktop smoke test."""
import tkinter as tk
import ctypes
from ctypes import wintypes

root = tk.Tk()
root.title("Expert Chat desktop validation")
root.geometry("420x130+20+20")
tk.Label(root, text="Desktop background-control test\nThis test window should keep focus.", padx=20, pady=25).pack()

def ready():
    root.lift()
    root.focus_force()
    user32 = ctypes.windll.user32
    user32.GetAncestor.argtypes = [wintypes.HWND, wintypes.UINT]
    user32.GetAncestor.restype = wintypes.HWND
    user32.SetForegroundWindow.argtypes = [wintypes.HWND]
    user32.SetForegroundWindow(user32.GetAncestor(root.winfo_id(), 2))
    root.after(500, lambda: print("ready", flush=True))

root.after(250, ready)
root.after(60000, root.destroy)
root.mainloop()
