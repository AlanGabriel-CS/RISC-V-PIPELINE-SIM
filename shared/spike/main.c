int main() {
    volatile int sum = 0;
    
    // A loop that runs many iterations to generate thousands of instructions
    for (int i = 0; i < 500; i++) {
        sum += i * 3;
        sum ^= (i << 1);
    }
    
    return sum;
}