using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Accessibility;

public class AcceptanceMsaaResult {
  public int Nodes;
  public bool Marker;
  public bool Send;
  public int Errors;
}
public static class AcceptanceMsaaProbe {
  private delegate bool EnumChildProc(IntPtr hwnd, IntPtr parameter);
  [DllImport("user32.dll")]
  private static extern bool EnumChildWindows(IntPtr parent, EnumChildProc callback, IntPtr parameter);
  [DllImport("oleacc.dll")]
  private static extern int AccessibleObjectFromWindow(IntPtr hwnd, uint objectId, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IAccessible accessible);
  [DllImport("oleacc.dll")]
  private static extern int AccessibleChildren(IAccessible accessible, int start, int count, [Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex=2)] object[] children, out int obtained);
  public static AcceptanceMsaaResult Read(IntPtr parent) {
    var result = new AcceptanceMsaaResult();
    var windows = new List<IntPtr>(); windows.Add(parent);
    EnumChildWindows(parent, delegate(IntPtr child, IntPtr unused) { windows.Add(child); return true; }, IntPtr.Zero);
    foreach (var window in windows) {
      try {
        Guid iid = new Guid("618736e0-3c3d-11cf-810c-00aa00389b71");
        IAccessible root;
        if (AccessibleObjectFromWindow(window, unchecked((uint)-4), ref iid, out root) != 0 || root == null) continue;
        var pending = new Queue<IAccessible>(); pending.Enqueue(root);
        var seen = new HashSet<IAccessible>();
        while (pending.Count > 0 && result.Nodes < 2000) {
          var node = pending.Dequeue();
          if (!seen.Add(node)) continue;
          result.Nodes++;
          try {
            Match(result, node.get_accName(0));
            int count = Math.Min(node.accChildCount, 2000 - result.Nodes);
            if (count <= 0) continue;
            object[] children = new object[count]; int obtained;
            AccessibleChildren(node, 0, count, children, out obtained);
            for (int i = 0; i < obtained; i++) {
              var child = children[i] as IAccessible;
              if (child != null) pending.Enqueue(child);
              else if (children[i] is int) { Match(result, node.get_accName(children[i])); result.Nodes++; }
            }
          } catch { result.Errors++; }
        }
      } catch { result.Errors++; }
    }
    return result;
  }
  private static void Match(AcceptanceMsaaResult result, string name) {
    if (name == null) return;
    if (name.Contains("acceptance-uia-marker")) result.Marker = true;
    if (name == "\u53d1\u9001") result.Send = true;
  }
}
