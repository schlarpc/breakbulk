#include <stdio.h>

unsigned int both_answer(void);
unsigned int stat_answer(void);

int main(void) {
    printf("c %u %u\n", both_answer(), stat_answer());
    return 0;
}
