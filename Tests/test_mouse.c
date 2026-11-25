#include <assert.h>
#include <stdio.h>
#include <setjmp.h>
#include <string.h>
#define API
#include "../WineHelper/mouse.c"
static jmp_buf finish;
static const char *chosen = "", *candidateName = "Game.ExE", *running = "";
static void widen(const char *s, WCHAR *out) { while (*s) *out++ = (unsigned char)*s++; *out=0; }
DWORD GetEnvironmentVariableW(const WCHAR *key,WCHAR *out,DWORD cap){widen(chosen,out);return (DWORD)strlen(chosen);}
static int lower16(int c){return c >= 'A' && c <= 'Z' ? c+32:c;}
int CompareStringOrdinal(const WCHAR *a,int alen,const WCHAR *b,int blen,BOOL fold){
    while(*a && lower16(*a)==lower16(*b)){a++;b++;}
    return lower16(*a)==lower16(*b)?2:1;
}
HANDLE OpenProcess(DWORD rights,BOOL inherit,DWORD pid){return (HANDLE)1;}
BOOL QueryFullProcessImageNameW(HANDLE proc,DWORD flags,WCHAR *out,DWORD *cnt){widen(running,out);return 1;}
HANDLE CreateFileW(const WCHAR *path,DWORD access,DWORD share,void *sa,DWORD mode,DWORD attrs,HANDLE temp){
    WCHAR selected[512];widen(chosen,selected);
    return CompareStringOrdinal(path,-1,selected,-1,1)==2?(HANDLE)1:(HANDLE)2;
}
BOOL GetFileInformationByHandle(HANDLE f,FILEINFO *info){memset(info,0,sizeof(*info));info->volume=1;info->indexLow=(DWORD)(WORDPTR)f;return 1;}
static const char *script;
static int steps, pending, inGame, physical, gameExists;
static char transitions[64], statusLog[64];
static int buttonCount, stateCount;
HANDLE GetStdHandle(DWORD h) { return (HANDLE)(WORDPTR)h; }
BOOL WriteFile(HANDLE h,const void *p,DWORD n,DWORD *w,void *ov) { statusLog[stateCount++]=*(const char *)p;*w=n;return 1; }
BOOL ReadFile(HANDLE h,void *p,DWORD n,DWORD *w,void *ov) {return 0;}
HANDLE CreateThread(void *s,WORDPTR n,DWORD (*f)(void *),void *a,DWORD b,DWORD *c){return (HANDLE)1;}
DWORD GetCurrentThreadId(void){return 1;}
HANDLE CreateToolhelp32Snapshot(DWORD a,DWORD b){return (HANDLE)1;}
BOOL Process32FirstW(HANDLE list,PROCESSENTRY *e){const char *n=gameExists?candidateName:"patcher.exe";int i=0;for(;n[i];i++)e->name[i]=n[i];e->name[i]=0;e->pid=42;return 1;}
BOOL Process32NextW(HANDLE h,PROCESSENTRY *p){return 0;}
BOOL CloseHandle(HANDLE h){return 1;}
void ExitProcess(UINT u){assert(!u);longjmp(finish,1);}
DWORD GetTickCount(void){return steps*40;}
BOOL PostThreadMessageW(DWORD a,UINT b,WORDPTR c,long long d){return 1;}
BOOL PeekMessageW(MSG *m,HANDLE h,UINT a,UINT b,UINT remove){if(!remove || !pending)return 0;m->message=commandMessage;m->wp=pending;pending=0;return 1;}
DWORD MsgWaitForMultipleObjects(DWORD n,const HANDLE *h,BOOL a,DWORD ms,DWORD mask){char command=script[steps++];assert(command);if(command=='B')inGame=0;else if(command=='F')inGame=1;else pending=command;return 0;}
HANDLE GetForegroundWindow(void){return (HANDLE)1;}
DWORD GetWindowThreadProcessId(HANDLE w,DWORD *pid){*pid=inGame?42:9;return 1;}
UINT SendInput(UINT n,INPUT *in,int size){assert(n==1 && size==40 && in->kind==0);transitions[buttonCount++]=in->u.mouse.flags==8?'D':'U';return 1;}
short GetAsyncKeyState(int key){assert(key==2);return physical?(short)0x8000:0;}
static void check(const char *commands,int focus,int rmb,int exists,const char *expected){
    script=commands;steps=0;pending=0;inGame=focus;physical=rmb;gameExists=exists;
    previous=0;buttonCount=stateCount=0;memset(transitions,0,sizeof transitions);memset(statusLog,0,sizeof statusLog);
    if(!setjmp(finish)) start();
    assert(strcmp(transitions,expected)==0);
}
int main(void){
    check("",1,0,1,"");
    assert(strcmp(statusLog,"N")==0);
    chosen = "C:\\Games\\Example\\Game.exe";
    running = chosen;
    check("TTQ",1,0,1,"DU");
    assert(strchr(statusLog,'1') && strchr(statusLog,'0'));
    check("TBTFQ",1,0,1,"DU");
    check("TUQ",1,0,1,"DU");
    assert(strchr(statusLog,'1') && !strchr(statusLog,'0'));
    check("TQ",1,0,1,"DU");
    check("TQ",0,0,1,"");
    check("TQ",1,1,1,"");
    assert(!strchr(statusLog,'1') && !strchr(statusLog,'0'));
    check("",1,0,0,"");
    running = "C:\\Other\\Game.exe";
    check("",1,0,1,"");
    candidateName = "Launcher.exe";
    check("",1,0,1,"");
    puts("No selection, selected executable, duplicate filename, focus and toggle checks passed.");
}
