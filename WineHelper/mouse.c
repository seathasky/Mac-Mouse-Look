// Win64 helper, built without a C runtime. Every input event goes through Wine's user32.
typedef unsigned int DWORD;
typedef unsigned int UINT;
typedef unsigned long long WORDPTR;
typedef int BOOL;
typedef void *HANDLE;
typedef unsigned short WCHAR;
typedef struct {
    DWORD kind;
    union {
        struct { int x, y; DWORD data, flags, time; WORDPTR extra; } mouse;
    } u;
} INPUT;
typedef struct {
    DWORD size, usage, pid; WORDPTR heap;
    DWORD module, threads, parent; int priority; DWORD flags; WCHAR name[260];
} PROCESSENTRY;
typedef struct { HANDLE window; UINT message; WORDPTR wp; long long lp; DWORD time; int x, y; DWORD privateData; } MSG;
_Static_assert(sizeof(INPUT) == 40 && sizeof(PROCESSENTRY) == 568 && sizeof(MSG) == 48, "Win64 ABI");
#ifndef API
#define API __declspec(dllimport)
#endif
API HANDLE GetStdHandle(DWORD);
API BOOL WriteFile(HANDLE,const void *,DWORD,DWORD *,void *);
API BOOL ReadFile(HANDLE,void *,DWORD,DWORD *,void *);
API HANDLE CreateThread(void *,WORDPTR,DWORD (*)(void *),void *,DWORD,DWORD *);
API DWORD GetCurrentThreadId(void);
API HANDLE CreateToolhelp32Snapshot(DWORD,DWORD);
API BOOL Process32FirstW(HANDLE,PROCESSENTRY *);
API BOOL Process32NextW(HANDLE,PROCESSENTRY *);
API BOOL CloseHandle(HANDLE);
API void ExitProcess(UINT);
API DWORD GetTickCount(void);
API BOOL PostThreadMessageW(DWORD,UINT,WORDPTR,long long);
API BOOL PeekMessageW(MSG *,HANDLE,UINT,UINT,UINT);
API DWORD MsgWaitForMultipleObjects(DWORD,const HANDLE *,BOOL,DWORD,DWORD);
API HANDLE GetForegroundWindow(void);
API DWORD GetWindowThreadProcessId(HANDLE,DWORD *);
API UINT SendInput(UINT,INPUT *,int);
API short GetAsyncKeyState(int);
enum { commandMessage = 0x8001, rightDown = 8, rightUp = 16 };
static DWORD mainThread;
static char previous;
static void report(char state) {
    if (previous != state) {
        DWORD written;
        WriteFile(GetStdHandle(-11), &state, 1, &written, 0);
        previous = state;
    }
}
typedef struct {
    DWORD attributes, times[6], volume, sizeHigh, sizeLow, links, indexHigh, indexLow;
} FILEINFO;
API DWORD GetEnvironmentVariableW(const WCHAR *, WCHAR *, DWORD);
API int CompareStringOrdinal(const WCHAR *,int,const WCHAR *,int,BOOL);
API HANDLE OpenProcess(DWORD,BOOL,DWORD);
API BOOL QueryFullProcessImageNameW(HANDLE,DWORD,WCHAR *,DWORD *);
API HANDLE CreateFileW(const WCHAR *,DWORD,DWORD,void *,DWORD,DWORD,HANDLE);
API BOOL GetFileInformationByHandle(HANDLE,FILEINFO *);
static WCHAR selectedPath[32768], runningPath[32768];
static const WCHAR *targetName;
static FILEINFO selectedInfo;
static BOOL haveIdentity;
static BOOL identity(const WCHAR *path, FILEINFO *info) {
    HANDLE file = CreateFileW(path, 0, 7, 0, 3, 0, 0);
    if (file == (HANDLE)-1) return 0;
    BOOL ok = GetFileInformationByHandle(file, info);
    CloseHandle(file);
    return ok && (info->indexHigh || info->indexLow);
}
static BOOL loadTarget(void) {
    static const WCHAR variable[] = {'M','M','L','_','G','A','M','E',0};
    DWORD count = GetEnvironmentVariableW(variable, selectedPath, 32768);
    if (!count || count >= 32768) return 0;
    targetName = selectedPath;
    for (const WCHAR *p = selectedPath; *p; ++p)
        if (*p == 92 || *p == '/') targetName = p + 1;
    haveIdentity = identity(selectedPath, &selectedInfo);
    return *targetName != 0;
}
static BOOL isGame(const PROCESSENTRY *entry) {
    if (CompareStringOrdinal(entry->name,-1,targetName,-1,1) != 2) return 0;
    HANDLE process = OpenProcess(0x1000,0,entry->pid);
    if (!process) return 0;
    DWORD size = 32768;
    BOOL ok = QueryFullProcessImageNameW(process,0,runningPath,&size);
    CloseHandle(process);
    if (!ok) return 0;
    FILEINFO info;
    if (haveIdentity && identity(runningPath,&info))
        return info.volume == selectedInfo.volume && info.indexHigh == selectedInfo.indexHigh && info.indexLow == selectedInfo.indexLow;
    return CompareStringOrdinal(runningPath,-1,selectedPath,-1,1) == 2;
}
static DWORD findGame(void) {
    HANDLE list = CreateToolhelp32Snapshot(2, 0);
    if (list == (HANDLE)-1) return 0;
    PROCESSENTRY entry;
    entry.size = sizeof(entry);
    DWORD pid = 0;
    if (Process32FirstW(list, &entry)) do {
        if (isGame(&entry)) { pid = entry.pid; break; }
    } while (Process32NextW(list, &entry));
    CloseHandle(list);
    return pid;
}
static DWORD readCommands(void *unused) {
    (void)unused;
    char cmd;
    DWORD n;
    while (ReadFile(GetStdHandle(-10), &cmd, 1, &n, 0) && n == 1) {
        if (!PostThreadMessageW(mainThread, commandMessage, cmd, 0)) break;
    }
    PostThreadMessageW(mainThread, commandMessage, 'Q', 0);
    return 0;
}
static BOOL mouseButton(DWORD flag) {
    INPUT event = {0};
    event.u.mouse.flags = flag;
    return SendInput(1, &event, sizeof(event)) == 1;
}
void start(void) {
    MSG msg;
    DWORD game = loadTarget() ? findGame() : 0;
    if (!game) { report('N'); ExitProcess(0); }
    mainThread = GetCurrentThreadId();
    PeekMessageW(&msg, 0, 0, 0, 0);
    HANDLE reader = CreateThread(0, 0, readCommands, 0, 0, 0);
    if (!reader) ExitProcess(2);
    DWORD checked = GetTickCount();
    BOOL held = 0, quit = 0;
    while (!quit) {
        DWORD front = 0;
        GetWindowThreadProcessId(GetForegroundWindow(), &front);
        if (held && front != game) held = !mouseButton(rightUp);
        report(front == game ? (held ? 'H' : 'R') : 'W');
        while (PeekMessageW(&msg, 0, 0, 0, 1)) {
            if (msg.message != commandMessage) continue;
            if (msg.wp == 'Q') { quit = 1; break; }
            if (held && (msg.wp == 'T' || msg.wp == 'U')) {
                held = !mouseButton(rightUp);
                if (!held && msg.wp == 'T') report('0');
            } else if (!held && msg.wp == 'T') {
                DWORD current = 0;
                GetWindowThreadProcessId(GetForegroundWindow(), &current);
                if (current == game && !(GetAsyncKeyState(2) & 0x8000)) {
                    held = mouseButton(rightDown);
                    report(held ? '1' : 'E');
                }
            }
        }
        if (GetTickCount() - checked >= 1500) {
            if (findGame() != game) break;
            checked = GetTickCount();
        }
        if (!quit) MsgWaitForMultipleObjects(0, 0, 0, 40, 0x04ff);
    }
    if (held) mouseButton(rightUp);
    ExitProcess(0);
}
