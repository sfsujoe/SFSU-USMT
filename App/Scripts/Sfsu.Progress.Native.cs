// UI-only control; the headless migration engine does not load Windows Forms.
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
namespace Sfsu.Ui {
 public sealed class ProgressPie : Control {
  double percent; string outcome="Running";
  public double Percent { get { return percent; } set { percent=Math.Max(0,Math.Min(100,value)); Invalidate(); } }
  public string Outcome { get { return outcome; } set { outcome=value; Invalidate(); } }
  public ProgressPie() { SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer|ControlStyles.ResizeRedraw,true); AccessibleRole=AccessibleRole.Graphic; }
  protected override void OnPaint(PaintEventArgs e) {
   base.OnPaint(e); e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;
   float size=Math.Min(ClientSize.Width,ClientSize.Height)-16; if(size<=0) return;
   RectangleF circle=new RectangleF((ClientSize.Width-size)/2,(ClientSize.Height-size)/2,size,size);
   bool full=outcome=="Failed" || outcome=="Completed" || outcome=="CompletedWithWarnings";
   Color color=Color.Gold;
   if(outcome=="Failed") color=Color.FromArgb(200,35,51);
   else if(outcome=="Completed") color=Color.FromArgb(28,139,69);
   else if(outcome=="CompletedWithWarnings") color=Color.FromArgb(232,163,23);
   else if(outcome=="Cancelled") color=Color.Gray;
   if(SystemInformation.HighContrast) color=ForeColor;
   using(Brush background=new SolidBrush(BackColor)) e.Graphics.FillEllipse(background,circle);
   using(Brush fill=new SolidBrush(color)) {
    if(full || percent>=100) e.Graphics.FillEllipse(fill,circle);
    else if(percent>0) e.Graphics.FillPie(fill,circle.X,circle.Y,circle.Width,circle.Height,0,(float)(360*percent/100));
   }
   using(Pen outline=new Pen(ForeColor,3)) e.Graphics.DrawEllipse(outline,circle);
   if(outcome=="Failed") {
    using(Pen cross=new Pen(SystemInformation.HighContrast ? BackColor : Color.White,Math.Max(6,size/40))) {
     e.Graphics.DrawLine(cross,circle.X+size*.36f,circle.Y+size*.36f,circle.X+size*.64f,circle.Y+size*.64f);
     e.Graphics.DrawLine(cross,circle.X+size*.64f,circle.Y+size*.36f,circle.X+size*.36f,circle.Y+size*.64f);
    }
   } else if(outcome=="Completed") {
    using(Pen check=new Pen(SystemInformation.HighContrast ? BackColor : Color.White,Math.Max(6,size/40))) {
     e.Graphics.DrawLine(check,circle.X+size*.30f,circle.Y+size*.51f,circle.X+size*.44f,circle.Y+size*.65f);
     e.Graphics.DrawLine(check,circle.X+size*.44f,circle.Y+size*.65f,circle.X+size*.72f,circle.Y+size*.35f);
    }
   } else if(outcome=="CompletedWithWarnings") {
    using(Pen mark=new Pen(SystemInformation.HighContrast ? BackColor : Color.Black,Math.Max(6,size/35))) e.Graphics.DrawLine(mark,circle.X+size*.5f,circle.Y+size*.27f,circle.X+size*.5f,circle.Y+size*.57f);
    using(Brush dot=new SolidBrush(SystemInformation.HighContrast ? BackColor : Color.Black)) e.Graphics.FillEllipse(dot,circle.X+size*.48f,circle.Y+size*.67f,size*.04f,size*.04f);
   }
  }
 }
}
