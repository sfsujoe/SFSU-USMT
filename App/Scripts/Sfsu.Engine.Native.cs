// Windows PowerShell 5.1 / .NET Framework. No credentials enter command lines.
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

namespace Sfsu.Engine {
 public static class Locations {
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint mode,uint flags,IntPtr template);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint GetFinalPathNameByHandle(SafeFileHandle file,StringBuilder name,uint length,uint flags);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool GetDiskFreeSpaceEx(string path,out ulong available,out ulong total,out ulong free);
  public static ulong FreeBytes(string path) { ulong available,total,free; if(!GetDiskFreeSpaceEx(path,out available,out total,out free)) throw new Win32Exception(); return available; }
  public static string FinalDirectory(string path) {
   using(SafeFileHandle handle=CreateFile(path,0,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero)) {
    if(handle.IsInvalid) throw new Win32Exception(); StringBuilder value=new StringBuilder(32768);
    uint count=GetFinalPathNameByHandle(handle,value,(uint)value.Capacity,0); if(count==0 || count>=value.Capacity) throw new Win32Exception();
    string result=value.ToString(); if(result.StartsWith(@"\\?\UNC\")) return @"\\"+result.Substring(8); if(result.StartsWith(@"\\?\")) return result.Substring(4); return result;
   }
  }
 }
 public sealed class NativeRun : IDisposable {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Startup {
   public int cb; public string reserved, desktop, title; public uint x,y,xSize,ySize,xCount,yCount,fill,flags;
   public ushort show,reservedSize; public IntPtr reserved2,input,output,error;
  }
  [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr process,thread; public uint pid,tid; }
  [StructLayout(LayoutKind.Sequential)] struct BasicLimits { public long processTime,jobTime; public uint flags; public UIntPtr min,max; public uint active; public UIntPtr affinity; public uint priority,scheduling; }
  [StructLayout(LayoutKind.Sequential)] struct Io { public ulong a,b,c,d,e,f; }
  [StructLayout(LayoutKind.Sequential)] struct Limits { public BasicLimits basic; public Io io; public UIntPtr processMemory,jobMemory,peakProcess,peakJob; }
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr a,string name);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int info,ref Limits data,uint size);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcess(string app,StringBuilder args,IntPtr p,IntPtr t,bool inherit,uint flags,IntPtr env,string cwd,ref Startup si,out ProcessInfo pi);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
  [DllImport("kernel32.dll",SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateProcess(IntPtr process,uint code);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateJobObject(IntPtr job,uint code);
  [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr process,out uint code);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  IntPtr job=IntPtr.Zero, process=IntPtr.Zero;
  public readonly uint Pid;
  public NativeRun(string executable,string arguments,string directory) {
   ProcessInfo pi=new ProcessInfo();
   try {
    job=CreateJobObject(IntPtr.Zero,null); if(job==IntPtr.Zero) throw new Win32Exception();
    Limits limits=new Limits(); limits.basic.flags=0x2000; // KILL_ON_JOB_CLOSE
    if(!SetInformationJobObject(job,9,ref limits,(uint)Marshal.SizeOf(typeof(Limits)))) throw new Win32Exception();
    Startup si=new Startup(); si.cb=Marshal.SizeOf(typeof(Startup));
    // Suspended creation closes the race in which mighost could escape the job.
    if(!CreateProcess(executable,new StringBuilder("\""+executable+"\" "+arguments),IntPtr.Zero,IntPtr.Zero,false,0x08000004,IntPtr.Zero,directory,ref si,out pi)) throw new Win32Exception();
    process=pi.process; Pid=pi.pid;
    if(!AssignProcessToJobObject(job,process)) throw new Win32Exception();
    if(ResumeThread(pi.thread)==UInt32.MaxValue) throw new Win32Exception();
   } catch { if(process!=IntPtr.Zero) TerminateProcess(process,1223); Dispose(); throw; }
   finally { if(pi.thread!=IntPtr.Zero) CloseHandle(pi.thread); }
  }
  public bool Poll(int milliseconds) { uint result=WaitForSingleObject(process,(uint)milliseconds); if(result==UInt32.MaxValue) throw new Win32Exception(); return result==0; }
  public int ExitCode { get { uint code; if(!GetExitCodeProcess(process,out code)) throw new Win32Exception(); return unchecked((int)code); } }
  public void Dispose() {
   if(job!=IntPtr.Zero) { TerminateJobObject(job,1223); CloseHandle(job); job=IntPtr.Zero; }
   if(process!=IntPtr.Zero) { WaitForSingleObject(process,5000); CloseHandle(process); process=IntPtr.Zero; }
  }
 }

 public static class Accounts {
  [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct User1 { public string name; public IntPtr password; public uint age,privilege; public string home,comment; public uint flags; public string script; }
  [StructLayout(LayoutKind.Sequential)] struct Flags { public uint value; }
  [StructLayout(LayoutKind.Sequential)] struct Member { public IntPtr sid; }
  [StructLayout(LayoutKind.Sequential)] struct Luid { public uint low; public int high; }
  [StructLayout(LayoutKind.Sequential)] struct Privilege { public uint count; public Luid luid; public uint attributes; }
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
  [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr value);
  [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool LookupPrivilegeValue(string system,string name,out Luid luid);
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr token,bool disable,ref Privilege state,uint size,IntPtr previous,IntPtr length);
  [DllImport("netapi32.dll",CharSet=CharSet.Unicode)] static extern int NetUserAdd(string server,int level,ref User1 user,out uint parameter);
  [DllImport("netapi32.dll",CharSet=CharSet.Unicode)] static extern int NetUserGetInfo(string server,string user,int level,out IntPtr buffer);
  [DllImport("netapi32.dll",CharSet=CharSet.Unicode)] static extern int NetUserSetInfo(string server,string user,int level,ref Flags flags,out uint parameter);
  [DllImport("netapi32.dll",CharSet=CharSet.Unicode)] static extern int NetLocalGroupAddMembers(string server,string group,int level,ref Member member,int total);
  [DllImport("netapi32.dll",CharSet=CharSet.Unicode)] static extern int NetLocalGroupDelMembers(string server,string group,int level,ref Member member,int total);
  [DllImport("netapi32.dll",CharSet=CharSet.Unicode)] static extern int NetUserGetLocalGroups(string server,string user,int level,uint flags,out IntPtr buffer,int size,out int read,out int total);
  [DllImport("netapi32.dll")] static extern int NetApiBufferFree(IntPtr buffer);
  [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegLoadAppKey(string file,out SafeRegistryHandle key,int access,int options,int reserved);
  static void Check(int result,string action) { if(result!=0) throw new Win32Exception(result,action+" (Windows error "+result+")."); }
  public static RegistryKey OpenHive(string path) {
   SafeRegistryHandle handle; int result=RegLoadAppKey(path,out handle,0x20019,1,0);
   if(result!=0) { if(handle!=null) handle.Dispose(); Check(result,"Cannot inspect the user registry hive"); }
   try { return RegistryKey.FromHandle(handle,RegistryView.Registry64); } catch { handle.Dispose(); throw; }
  }
  public static void EnablePrivileges() {
   IntPtr token; if(!OpenProcessToken(GetCurrentProcess(),0x28,out token)) throw new Win32Exception();
   try { foreach(string name in new string[]{"SeBackupPrivilege","SeRestorePrivilege","SeSecurityPrivilege","SeTakeOwnershipPrivilege","SeDebugPrivilege"}) {
    Privilege state=new Privilege(); state.count=1; state.attributes=2;
    if(!LookupPrivilegeValue(null,name,out state.luid)) throw new Win32Exception();
    if(!AdjustTokenPrivileges(token,false,ref state,0,IntPtr.Zero,IntPtr.Zero) || Marshal.GetLastWin32Error()!=0) throw new Win32Exception(Marshal.GetLastWin32Error(),"Required USMT privilege unavailable: "+name);
   }} finally { CloseHandle(token); }
  }
  public static bool Exists(string name) {
   IntPtr buffer; int result=NetUserGetInfo(null,name,1,out buffer);
   if(buffer!=IntPtr.Zero) NetApiBufferFree(buffer);
   if(result==2221) return false; Check(result,"Cannot check local account"); return true;
  }
  public static string CreateDisabled(string name,SecureString password) {
   if(password==null || password.Length==0) throw new ArgumentException("A nonempty account password is required.");
   IntPtr secret=Marshal.SecureStringToGlobalAllocUnicode(password);
   try {
    User1 user=new User1(); user.name=name; user.password=secret; user.privilege=1; user.flags=0x203;
    uint parameter; Check(NetUserAdd(null,1,ref user,out parameter),"Cannot create the disabled local account; check the local password/account policy");
   } finally { Marshal.ZeroFreeGlobalAllocUnicode(secret); }
   try { return ((SecurityIdentifier)new NTAccount(Environment.MachineName,name).Translate(typeof(SecurityIdentifier))).Value; }
   catch { SetEnabled(name,false); throw; }
  }
  public static bool Enabled(string name) {
   IntPtr buffer; Check(NetUserGetInfo(null,name,1,out buffer),"Cannot read local account status");
   try { return (((User1)Marshal.PtrToStructure(buffer,typeof(User1))).flags & 2)==0; } finally { NetApiBufferFree(buffer); }
  }
  public static void SetEnabled(string name,bool enabled) {
   IntPtr buffer; Check(NetUserGetInfo(null,name,1,out buffer),"Cannot read local account flags"); Flags flags=new Flags();
   try { flags.value=((User1)Marshal.PtrToStructure(buffer,typeof(User1))).flags; } finally { NetApiBufferFree(buffer); }
   flags.value=enabled ? flags.value & ~2u : flags.value | 2u; uint parameter;
   Check(NetUserSetInfo(null,name,1008,ref flags,out parameter),"Cannot set local account enabled state");
  }
  static string GroupName(string sid) { string name=((NTAccount)new SecurityIdentifier(sid).Translate(typeof(NTAccount))).Value; return name.Substring(name.IndexOf('\\')+1); }
  public static void SetGroup(string accountSid,string groupSid,bool member) {
   SecurityIdentifier sid=new SecurityIdentifier(accountSid); byte[] data=new byte[sid.BinaryLength]; sid.GetBinaryForm(data,0);
   IntPtr pointer=Marshal.AllocHGlobal(data.Length);
   try { Marshal.Copy(data,0,pointer,data.Length); Member item=new Member(); item.sid=pointer;
    int result=member ? NetLocalGroupAddMembers(null,GroupName(groupSid),0,ref item,1) : NetLocalGroupDelMembers(null,GroupName(groupSid),0,ref item,1);
    if((member && result==1378) || (!member && result==1377)) return; Check(result,"Cannot apply local group membership");
   } finally { Marshal.FreeHGlobal(pointer); }
  }
  public static bool IsAdministrator(string name) {
   IntPtr buffer; int read,total; Check(NetUserGetLocalGroups(null,name,0,1,out buffer,-1,out read,out total),"Cannot verify local groups");
   try { string admin=GroupName("S-1-5-32-544"); for(int i=0;i<read;i++) { string group=Marshal.PtrToStringUni(Marshal.ReadIntPtr(buffer,i*IntPtr.Size)); if(String.Equals(group,admin,StringComparison.OrdinalIgnoreCase)) return true; } return false; }
   finally { NetApiBufferFree(buffer); }
  }
 }
}
