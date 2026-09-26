#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
int main(void)
{
    static const WCHAR marker[] = L"RELAY_PRIVATE_SENTINEL_7f842a";
    static const WCHAR lowercase[] = L"relay_private_sentinel_7f842a";
    int comparison = CompareStringOrdinal(marker, -1, lowercase, -1, TRUE);
    int case_sensitive = CompareStringOrdinal(marker, -1, lowercase, -1, FALSE);
    int arithmetic = MulDiv(5, 2, 4);
    printf("comparison=%d case_sensitive=%d arithmetic=%d\n",
           comparison, case_sensitive, arithmetic);
    return comparison == CSTR_EQUAL && case_sensitive == CSTR_LESS_THAN &&
           arithmetic == 3 ? 0 : 1;
}
