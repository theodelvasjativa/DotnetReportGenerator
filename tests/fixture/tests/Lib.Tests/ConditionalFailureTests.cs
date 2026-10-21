using Lib;
using Xunit;

namespace Lib.Tests;

// Fails only when SMOKE_FAIL=1, so the same fixture can exercise both the
// success and the failing-test paths.
public class ConditionalFailureTests
{
    [Fact]
    public void Passes_Unless_SmokeFail_Is_Set()
    {
        var shouldFail = Environment.GetEnvironmentVariable("SMOKE_FAIL") == "1";
        Assert.False(shouldFail, "Fallo provocado por SMOKE_FAIL=1.");
        Assert.Equal(2, Calculator.Add(1, 1));
    }
}
