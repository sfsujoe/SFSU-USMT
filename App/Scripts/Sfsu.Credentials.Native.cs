using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security;

namespace Sfsu.SignIn {
 public sealed class Credential : IDisposable {
  public string UserName { get; private set; }
  public SecureString Password { get; private set; }
  internal Credential(string user, SecureString password) { UserName=user; Password=password; }
  public SecureString TakePassword() { SecureString value=Password; Password=null; return value; }
  public void Dispose() { if(Password!=null) { Password.Dispose(); Password=null; } }
 }
 public static class Native {
  [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]
  struct UiInfo { public int Size; public IntPtr Parent; public string Message, Caption; public IntPtr Banner; }
  [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]
  struct Resource { public int Scope,Type,DisplayType,Usage; public string Local,Remote,Comment,Provider; }
  [DllImport("credui.dll",CharSet=CharSet.Unicode,ExactSpelling=true)]
  static extern int CredUIPromptForWindowsCredentialsW(ref UiInfo info,int error,ref uint package,IntPtr input,uint inputSize,out IntPtr output,out uint outputSize,ref bool save,uint flags);
  [DllImport("credui.dll",CharSet=CharSet.Unicode,ExactSpelling=true,SetLastError=true)]
  [return:MarshalAs(UnmanagedType.Bool)]
  static extern bool CredUnPackAuthenticationBufferW(uint flags,IntPtr buffer,uint size,IntPtr user,ref uint userSize,IntPtr domain,ref uint domainSize,IntPtr password,ref uint passwordSize);
  [DllImport("mpr.dll",CharSet=CharSet.Unicode,ExactSpelling=true)]
  static extern int WNetAddConnection2W(ref Resource resource,IntPtr password,string user,uint flags);
  static void ClearFree(IntPtr value,int bytes,bool taskMemory) {
   if(value==IntPtr.Zero) return;
   try { for(int i=0;i<bytes;i++) Marshal.WriteByte(value,i,0); }
   finally { if(taskMemory) Marshal.FreeCoTaskMem(value); else Marshal.FreeHGlobal(value); }
  }
  internal static Credential Unpack(IntPtr buffer,uint size) {
   uint users=0,domains=0,passwords=0;
   bool measured=CredUnPackAuthenticationBufferW(0,buffer,size,IntPtr.Zero,ref users,IntPtr.Zero,ref domains,IntPtr.Zero,ref passwords);
   if(!measured && Marshal.GetLastWin32Error()!=122) throw new InvalidOperationException("Windows could not read the supplied username/password credentials. Use your university UPN and password.");
   if(users<1 || users>4096 || domains>4096 || passwords<1 || passwords>4097) throw new InvalidOperationException("The Windows credential result has an unsupported size.");
   int ub=checked((int)users*2),db=checked((int)Math.Max(domains,1)*2),pb=checked((int)passwords*2);
   IntPtr user=IntPtr.Zero,domain=IntPtr.Zero,password=IntPtr.Zero;
   SecureString secret=null;
   try {
    user=Marshal.AllocHGlobal(ub); domain=Marshal.AllocHGlobal(db); password=Marshal.AllocHGlobal(pb);
    for(int i=0;i<ub;i++) Marshal.WriteByte(user,i,0);
    for(int i=0;i<db;i++) Marshal.WriteByte(domain,i,0);
    for(int i=0;i<pb;i++) Marshal.WriteByte(password,i,0);
    if(!CredUnPackAuthenticationBufferW(0,buffer,size,user,ref users,domain,ref domains,password,ref passwords)) throw new InvalidOperationException("Windows could not unpack the supplied credentials.");
    string name=Marshal.PtrToStringUni(user)??String.Empty,realm=Marshal.PtrToStringUni(domain)??String.Empty;
    if(!String.IsNullOrEmpty(realm) && name.IndexOf('@')<0 && name.IndexOf('\\')<0) name=realm+"\\"+name;
    secret=new SecureString();
    for(int i=0;i<pb/2;i++) { char c=(char)Marshal.ReadInt16(password,i*2); if(c=='\0') break; secret.AppendChar(c); }
    if(String.IsNullOrWhiteSpace(name) || secret.Length==0) throw new InvalidOperationException("Enter your university UPN and password.");
    secret.MakeReadOnly(); Credential result=new Credential(name,secret); secret=null; return result;
   } finally { if(secret!=null) secret.Dispose(); ClearFree(password,pb,false); ClearFree(domain,db,false); ClearFree(user,ub,false); }
  }
  public static Credential Prompt(string message) {
   UiInfo info=new UiInfo(); info.Size=Marshal.SizeOf(typeof(UiInfo)); info.Caption="SFSU USMT sign-in"; info.Message=message;
   uint package=0,size=0; IntPtr buffer=IntPtr.Zero; bool save=false;
   try {
    // Generic username/password credentials; no save checkbox or persistence.
    int result=CredUIPromptForWindowsCredentialsW(ref info,0,ref package,IntPtr.Zero,0,out buffer,out size,ref save,1);
    if(result==1223) return null;
    if(result!=0) throw new Win32Exception(result,"Windows credential sign-in could not open (Windows error "+result+").");
    if(buffer==IntPtr.Zero || size==0 || size>1048576) throw new InvalidOperationException("Windows returned an invalid credential buffer.");
    return Unpack(buffer,size);
   } finally { if(buffer!=IntPtr.Zero) { if(size<=Int32.MaxValue) ClearFree(buffer,(int)size,true); else Marshal.FreeCoTaskMem(buffer); } }
  }
  public static int Connect(string share,string user,SecureString password) {
   if(password==null || password.Length==0) throw new ArgumentException("A password is required for toolkit share authentication.");
   Resource resource=new Resource(); resource.Type=1; resource.Remote=share;
   IntPtr secret=Marshal.SecureStringToGlobalAllocUnicode(password);
   try { return WNetAddConnection2W(ref resource,secret,user,0); }
   finally { Marshal.ZeroFreeGlobalAllocUnicode(secret); }
  }
 }
}
