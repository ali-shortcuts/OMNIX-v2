using System;
using System.Globalization;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;

namespace Omnix.Desktop
{
    public sealed class SelectionSnapshot : IDisposable
    {
        public string Label { get; internal set; }
        public string Text { get; internal set; }
        public bool CanApply { get; internal set; }
        internal object Document,Target;
        internal string Identity;
        internal int Rows,Columns;
        public void Dispose() { Release(Target); Target=null; Release(Document); Document=null; }
        internal static void Release(object value) { if(value!=null && Marshal.IsComObject(value)) Marshal.ReleaseComObject(value); }
    }
    public sealed class OfficeSelection
    {
        private readonly dynamic app;
        private readonly string host;
        private SelectionSnapshot undoTarget;
        private string appliedText;
        private object oldValues;
        private string oldWordXml;
        public OfficeSelection(object application,string hostName) { app=application; host=hostName; }
        private static bool Same(object a,object b)
        {
            if(a==null||b==null) return false;
            if(!Marshal.IsComObject(a)||!Marshal.IsComObject(b)) return ReferenceEquals(a,b);
            IntPtr first=Marshal.GetIUnknownForObject(a),second=Marshal.GetIUnknownForObject(b);
            try { return first==second; } finally { Marshal.Release(first); Marshal.Release(second); }
        }
        public SelectionSnapshot Capture()
        {
            var result=new SelectionSnapshot();
            try {
                if(host=="Excel") {
                    result.Document=app.ActiveWorkbook;
                    if(result.Document==null) throw new InvalidOperationException("Open a workbook first.");
                    dynamic range=app.Selection; result.Target=range;
                    if(range==null || (long)range.CountLarge>200 || (int)range.Areas.Count!=1) throw new InvalidOperationException("Select one rectangular range of at most 200 cells.");
                    result.Rows=(int)range.Rows.Count; result.Columns=(int)range.Columns.Count;
                    result.Identity=Convert.ToString(range.Address[true,true,1,true]);
                    result.Label="Excel selection · "+result.Rows+" rows × "+result.Columns+" columns";
                    result.Text=ReadRange(range,result.Rows,result.Columns);
                    result.CanApply=result.Rows==1 && result.Columns==1 && !(bool)range.MergeCells && !(bool)range.HasArray;
                } else if(host=="Word") {
                    result.Document=app.ActiveDocument;
                    if(result.Document==null) throw new InvalidOperationException("Open a document first.");
                    dynamic range=app.Selection.Range.Duplicate; result.Target=range;
                    result.Identity=range.Start+":"+range.End+":"+range.StoryType;
                    result.Label="Word selection"; result.Text=(string)range.Text??"";
                    result.CanApply=result.Text.Length>0 && result.Text.Length<=16000 && (int)range.Tables.Count==0 && !(bool)range.Information[12];
                } else {
                    result.Document=app.ActivePresentation;
                    if(result.Document==null) throw new InvalidOperationException("Open a presentation first.");
                    dynamic selection=app.ActiveWindow.Selection;
                    if((int)selection.Type!=3) throw new InvalidOperationException("Select text in a slide text box first.");
                    dynamic range=selection.TextRange; result.Target=range;
                    result.Text=(string)range.Text??"";
                    result.Identity=range.Start+":"+range.Length;
                    result.Label="PowerPoint selected text";
                    result.CanApply=result.Text.Length>0 && result.Text.Length<=16000;
                }
                if(result.Text.Length>16000) { result.Text=result.Text.Substring(0,16000)+"\n[Selection truncated]"; result.CanApply=false; }
                return result;
            } catch { result.Dispose(); throw; }
        }
        private static string ReadRange(dynamic range,int rows,int cols)
        {
            object value=range.Value2;
            if(rows==1 && cols==1) return Convert.ToString(value,CultureInfo.InvariantCulture)??"";
            var data=value as Array; var output=new StringBuilder();
            for(int row=1;row<=rows;row++) {
                if(row>1)output.AppendLine();
                for(int col=1;col<=cols;col++) {
                    if(col>1)output.Append('\t');
                    output.Append(Convert.ToString(data?.GetValue(row,col),CultureInfo.InvariantCulture));
                    if(output.Length>16000) return output.ToString();
                }
            }
            return output.ToString();
        }
        public void Apply(SelectionSnapshot target,string text,bool formula)
        {
            if(target==null || !target.CanApply) throw new InvalidOperationException("Capture an editable selection first. Excel writes support a single unmerged cell.");
            if(string.IsNullOrEmpty(text) || text.Length>30000) throw new InvalidOperationException("The proposed change must contain 1–30,000 characters.");
            using(var current=Capture()) {
                if(!Same(current.Document,target.Document)||current.Identity!=target.Identity||current.Text!=target.Text)
                    throw new InvalidOperationException("The selection or its contents changed. Capture it again before applying.");
                if(host=="PowerPoint" && !Same(((dynamic)current.Target).Parent,((dynamic)target.Target).Parent))
                    throw new InvalidOperationException("The selected text box changed. Capture it again.");
            }
            dynamic range=target.Target;
            if(host=="Excel") {
                if((bool)range.Worksheet.ProtectContents && (bool)range.Locked) throw new InvalidOperationException("This cell is protected.");
                oldValues=range.Formula;
                if(formula) {
                    if(!text.StartsWith("=",StringComparison.Ordinal) || text.IndexOfAny(new[]{'[',']','|','\r','\n'})>=0 ||
                       new[]{"WEBSERVICE(","HYPERLINK(","RTD(","STOCKHISTORY(","IMAGE("}.Any(x=>text.ToUpperInvariant().Replace(" ","").Contains(x)))
                        throw new InvalidOperationException("Use a single formula without external links, network functions, or DDE.");
                    range.Formula=text;
                } else range.Value2="'"+text;
                appliedText=ReadRange(range,1,1);
            } else if(host=="Word") {
                if((bool)app.ActiveDocument.ReadOnly) throw new InvalidOperationException("The document is read-only.");
                oldWordXml=(string)range.WordOpenXML;
                if(oldWordXml.Length>4*1024*1024)throw new InvalidOperationException("This selection is too complex to preserve for undo.");
                app.UndoRecord.StartCustomRecord("OMNIX: apply selected text");
                try { range.Text=text; } finally { app.UndoRecord.EndCustomRecord(); }
                appliedText=(string)range.Text;
            } else {
                app.StartNewUndoEntry(); range.Text=text; appliedText=(string)range.Text;
            }
            undoTarget=target;
        }
        public void Undo()
        {
            if(undoTarget==null) throw new InvalidOperationException("There is no OMNIX change to undo in this pane.");
            dynamic document=host=="Excel"?app.ActiveWorkbook:host=="Word"?app.ActiveDocument:app.ActivePresentation;
            if(!Same(document,undoTarget.Document)) throw new InvalidOperationException("Return to the document changed by OMNIX.");
            dynamic range=undoTarget.Target;
            string now=host=="Excel"?ReadRange(range,1,1):(string)range.Text;
            if(now!=appliedText) throw new InvalidOperationException("The target was edited after OMNIX. Use Office's Undo history instead.");
            if(host=="Excel") range.Formula=oldValues;
            else if(host=="Word")range.InsertXML(oldWordXml);
            else range.Text=undoTarget.Text;
            undoTarget=null; oldValues=null;oldWordXml=null;
        }
    }
}
