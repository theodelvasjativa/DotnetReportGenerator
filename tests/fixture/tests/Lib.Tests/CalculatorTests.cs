using Lib;
using Xunit;

namespace Lib.Tests;

public class CalculatorTests
{
    [Fact]
    public void Add_ReturnsSum() => Assert.Equal(5, Calculator.Add(2, 3));

    [Fact]
    public void IsPositive_ReturnsTrue() => Assert.True(Calculator.IsPositive(1));
}
