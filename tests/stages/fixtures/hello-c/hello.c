#include <stdio.h>

static int answer(int x)
{
    int doubled = x * 2;
    return doubled + 0;
}

int main(void)
{
    printf("hello %d\n", answer(21));
    return 0;
}
