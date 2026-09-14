// Minimal deterministic Office object-model doubles. Real COM/VSTO acceptance is separate.
namespace Omnix.Tests
{
    public sealed class FakeCount {public int Count => 1;}
    public sealed class FakeAddress {public string this[bool row,bool column,int style,bool external] => "$A$1";}
    public sealed class FakeSheet {public bool ProtectContents => false;}
    public sealed class FakeRange
    {
        private object value="original";
        public long CountLarge => 1;
        public FakeCount Areas => new FakeCount();
        public FakeCount Rows => new FakeCount();
        public FakeCount Columns => new FakeCount();
        public FakeAddress Address => new FakeAddress();
        public bool MergeCells => false;
        public bool HasArray => false;
        public bool Locked => false;
        public FakeSheet Worksheet => new FakeSheet();
        public object Formula {get=>value;set=>this.value=value;}
        public object Value2 {get=>value;set=>this.value=value is string text&&text.StartsWith("'")?text.Substring(1):value;}
    }
    public sealed class FakeExcel
    {
        public object ActiveWorkbook {get;}=new object();
        public FakeRange Selection {get;}=new FakeRange();
    }
}
