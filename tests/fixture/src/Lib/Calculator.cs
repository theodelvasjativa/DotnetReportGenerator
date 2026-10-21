namespace Lib;

public static class Calculator
{
    public static int Add(int a, int b) => a + b;

    public static bool IsPositive(int value)
    {
        if (value > 0) return true;
        return false;
    }
}
