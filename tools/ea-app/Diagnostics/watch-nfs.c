#define UNICODE
#define _UNICODE
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <wchar.h>

/* Observe NFS termination metadata without opening its memory or command line. */
int main(void)
{
    const ULONGLONG deadline = GetTickCount64() + 180000;
    DWORD previous_pid = 0;
    setvbuf(stdout, NULL, _IONBF, 0);

    while (GetTickCount64() < deadline) {
        HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snapshot == INVALID_HANDLE_VALUE) {
            printf("snapshot_error=%lu\n", GetLastError());
            return 1;
        }

        PROCESSENTRY32W entry = {0};
        entry.dwSize = sizeof(entry);
        DWORD pid = 0;
        DWORD parent_pid = 0;
        unsigned matches = 0;
        if (Process32FirstW(snapshot, &entry)) {
            do {
                if (_wcsicmp(entry.szExeFile, L"NFS16.exe") == 0) {
                    pid = entry.th32ProcessID;
                    parent_pid = entry.th32ParentProcessID;
                    ++matches;
                }
            } while (Process32NextW(snapshot, &entry));
            if (GetLastError() != ERROR_NO_MORE_FILES) {
                printf("enumeration_error=%lu\n", GetLastError());
                CloseHandle(snapshot);
                return 1;
            }
        } else if (GetLastError() != ERROR_NO_MORE_FILES) {
            printf("enumeration_error=%lu\n", GetLastError());
            CloseHandle(snapshot);
            return 1;
        }
        CloseHandle(snapshot);

        if (matches > 1) {
            printf("multiple_game_processes=%u; observation_stopped\n", matches);
            return 2;
        }
        if (pid == 0 || pid == previous_pid) {
            Sleep(1000);
            continue;
        }

        HANDLE process = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
                                     FALSE, pid);
        if (process == NULL) {
            printf("pid=%lu open_error=%lu\n", pid, GetLastError());
            Sleep(1000);
            continue;
        }
        previous_pid = pid;
        printf("observing_pid=%lu hex=%04lx parent_pid=%lu\n", pid, pid, parent_pid);
        const ULONGLONG now = GetTickCount64();
        const DWORD wait_ms = now < deadline ? (DWORD)(deadline - now) : 0;
        const DWORD wait_result = WaitForSingleObject(process, wait_ms);
        if (wait_result == WAIT_OBJECT_0) {
            DWORD exit_code = 0;
            if (GetExitCodeProcess(process, &exit_code)) {
                printf("pid=%lu exit_code=0x%08lx elapsed_observation_ms=%llu\n",
                       pid, exit_code, GetTickCount64() - now);
            } else {
                printf("pid=%lu exit_code_error=%lu\n", pid, GetLastError());
                CloseHandle(process);
                return 1;
            }
        } else if (wait_result == WAIT_TIMEOUT) {
            printf("pid=%lu still_running_at_observation_deadline\n", pid);
        } else {
            printf("pid=%lu wait_error=%lu\n", pid, GetLastError());
            CloseHandle(process);
            return 1;
        }
        CloseHandle(process);
    }
    return 0;
}
