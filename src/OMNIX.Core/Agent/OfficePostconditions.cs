using System;
using System.Globalization;
using Newtonsoft.Json.Linq;
using OMNIX.Core.Context;
using Excel=Microsoft.Office.Interop.Excel;
using Word=Microsoft.Office.Interop.Word;
using Ppt=Microsoft.Office.Interop.PowerPoint;

namespace OMNIX.Core.Agent
{
    public static class OfficePostconditions
    {
        private static int Index(JObject c,string name,int fallback,int max)
        {
            int n=c[name]==null?fallback:(int)c[name];
            if(n<1 || n>max) throw new ArgumentException("Invalid "+name);
            return n;
        }
        public static bool ValuesEqual(object actual,JToken expected)
        {
            if(expected==null || expected.Type==JTokenType.Null) return actual==null;
            if(expected.Type==JTokenType.Boolean) return actual is bool && (bool)actual==(bool)expected;
            if(expected.Type==JTokenType.Integer || expected.Type==JTokenType.Float)
            {
                if(!(actual is double || actual is int || actual is decimal || actual is float || actual is long)) return false;
                double a=Convert.ToDouble(actual,CultureInfo.InvariantCulture), b=(double)expected;
                return !double.IsNaN(a) && !double.IsInfinity(a) && Math.Abs(a-b)<=1e-9*Math.Max(1,Math.Abs(b));
            }
            return actual is string && string.Equals((string)actual,(string)expected,StringComparison.Ordinal);
        }
        public static string ExcelCheck(Excel.Application app,JObject c)
        {
            ExecutionPlan.ValidateCheck(c,HostType.Excel);
            var sheet=(Excel.Worksheet)app.ActiveWorkbook.Worksheets[(string)c["sheet"]];
            var range=sheet.Range[(string)c["address"]];
            if(range.Areas.Count!=1 || Convert.ToInt64(range.Cells.CountLarge)>512) return "Check range must be contiguous and at most 512 cells.";
            string kind=(string)c["kind"];
            if(kind=="cell_value" || kind=="formula")
            {
                if(Convert.ToInt64(range.Cells.CountLarge)!=1) return "Value/formula checks require one cell.";
                if(kind=="formula")
                {
                    if(!Convert.ToBoolean(range.HasFormula)) return "Expected a real formula at "+(string)c["address"];
                    range.Calculate();
                    if(c["formula"]!=null && !string.Equals(Convert.ToString(range.Formula), (string)c["formula"],StringComparison.OrdinalIgnoreCase))
                        return "Formula reference differs from the plan at "+(string)c["address"];
                }
                return ValuesEqual(range.Value2,c["value"])?null:"Computed value/type differs from the plan at "+(string)c["address"];
            }
            if(kind=="format")
            {
                if(c["bold"]!=null && !ValuesEqual(range.Font.Bold,c["bold"])) return "Bold differs from the plan.";
                if(c["italic"]!=null && !ValuesEqual(range.Font.Italic,c["italic"])) return "Italic differs from the plan.";
                if(c["wrapText"]!=null && !ValuesEqual(range.WrapText,c["wrapText"])) return "Text wrapping differs from the plan.";
                if(c["fontSize"]!=null && !ValuesEqual(range.Font.Size,c["fontSize"])) return "Font size differs from the plan.";
                if(c["numberFormat"]!=null && !ValuesEqual(range.NumberFormat,c["numberFormat"])) return "Number format differs from the plan.";
                if(c["horizontalAlignment"]!=null)
                {
                    string alignment=(string)c["horizontalAlignment"];
                    int expected=alignment=="center"?(int)Excel.XlHAlign.xlHAlignCenter:alignment=="right"?(int)Excel.XlHAlign.xlHAlignRight:alignment=="left"?(int)Excel.XlHAlign.xlHAlignLeft:(int)Excel.XlHAlign.xlHAlignGeneral;
                    if(!ValuesEqual(range.HorizontalAlignment,new JValue(expected))) return "Horizontal alignment differs from the plan.";
                }
                return null;
            }
            if(kind=="heading")
            {
                var first=(Excel.Range)range.Cells[1,1];
                if(!Convert.ToBoolean(first.MergeCells) || first.MergeArea.Address[false,false]!=range.Address[false,false])
                    return "Heading frame does not match the planned range.";
                if(!ValuesEqual(first.Value2,c["text"])) return "Heading text differs from the plan.";
                foreach(Excel.ListObject table in sheet.ListObjects)
                    if(app.Intersect(range,table.Range)!=null) return "Heading overlaps a data table.";
                if(c["aboveTable"]!=null)
                {
                    var target=sheet.Range[(string)c["aboveTable"]];
                    bool found=false;
                    foreach(Excel.ListObject table in sheet.ListObjects)
                        if(table.Range.Address[false,false]==target.Address[false,false]) {found=true; break;}
                    if(!found) return "The table below the heading is absent.";
                    if(range.Row+range.Rows.Count>target.Row) return "Heading is not above the requested table.";
                }
                return null;
            }
            if(kind=="table")
            {
                foreach(Excel.ListObject table in sheet.ListObjects)
                    if(table.Range.Address[false,false]==range.Address[false,false])
                    {
                        if(c["rows"]!=null && table.ListRows.Count!=(int)c["rows"]) return "Table data row count differs from the plan.";
                        var headers=c["headers"] as JArray;
                        if(headers!=null)
                        {
                            if(table.ListColumns.Count!=headers.Count) return "Table column count differs from the plan.";
                            for(int i=0;i<headers.Count;i++)
                                if(!string.Equals(table.ListColumns[i+1].Name,(string)headers[i],StringComparison.Ordinal))
                                    return "Table header differs from the plan at column "+(i+1)+".";
                        }
                        var keys=c["keys"] as JArray;
                        if(keys!=null && keys.Count>0)
                        {
                            int column=(int)c["keyColumn"];
                            if(column>table.ListColumns.Count || table.DataBodyRange==null) return "Table key column is absent.";
                            // A single bulk read; no per-row COM traversal.
                            object stored=table.ListColumns[column].DataBodyRange.Value2;
                            var values=stored as Array;
                            for(int i=0;i<keys.Count;i++)
                                if(!ValuesEqual(values==null?stored:values.GetValue(i+1,1),keys[i]))
                                    return "Table record ID/type differs from the plan at data row "+(i+1)+".";
                        }
                        return null;
                    }
                return "No native table matches the planned range.";
            }
            // One bounded calculation instead of hundreds of cross-COM calls on the UI thread.
            // The expression is fixed; only Office's normalized A1 address is interpolated.
            string address = range.Address[true, true, Excel.XlReferenceStyle.xlA1];
            object errors = sheet.Evaluate("SUMPRODUCT(--ISERROR(" + address + "))");
            if (!(errors is double || errors is int)) return "Excel error scan could not be evaluated.";
            return Convert.ToDouble(errors, CultureInfo.InvariantCulture) == 0 ? null : "Excel errors exist in the checked range.";
        }
        // Remove only Office's terminal structural marker, preserving meaningful spaces and lines.
        public static string WordText(string text)
        {
            text = text ?? "";
            if (text.EndsWith("\r\a", StringComparison.Ordinal)) return text.Substring(0, text.Length - 2);
            if (text.EndsWith("\r", StringComparison.Ordinal)) return text.Substring(0, text.Length - 1);
            return text;
        }
        public static string NormalizeLineEndings(string text)
        {
            return text == null ? null : text.Replace("\r\n", "\n").Replace("\r", "\n");
        }
        public static bool TextMatches(string actual, string expected, bool exact)
        {
            if (actual == null || expected == null || actual.Length > 10000) return false;
            return exact ? string.Equals(NormalizeLineEndings(actual), NormalizeLineEndings(expected), StringComparison.Ordinal) : actual.Contains(expected);
        }
        public static string WordCheck(Word.Application app,JObject c)
        {
            ExecutionPlan.ValidateCheck(c,HostType.Word);
            var doc=app.ActiveDocument; string kind=(string)c["kind"];
            if(kind=="table_count") return doc.Tables.Count==(int)c["count"]?null:"Word table count differs from the plan.";
            if(kind=="table_content")
            {
                var table=doc.Tables[Index(c,"table",1,doc.Tables.Count)];
                var cells=(JArray)c["cells"]; int rows=cells.Count, columns=((JArray)cells[0]).Count;
                if(!table.Uniform || table.Rows.Count!=rows || table.Columns.Count!=columns)
                    return "Word table dimensions or merged structure differ from the plan.";
                for(int row=1;row<=rows;row++) for(int column=1;column<=columns;column++)
                {
                    var range=table.Cell(row,column).Range;
                    if(range.End-range.Start>502) return "Word table cell exceeds the bounded content check.";
                    if(!TextMatches(WordText(range.Text),(string)cells[row-1][column-1],true))
                        return "Word table cell content differs at row "+row+", column "+column+".";
                }
                return null;
            }
            int index=Index(c,"paragraph",1,doc.Paragraphs.Count);
            var p=doc.Paragraphs[index];
            if(kind=="paragraph_style")
            {
                var style=p.Range.get_Style() as Word.Style;
                return style!=null && style.NameLocal==(string)c["style"]?null:"Paragraph style differs from the plan.";
            }
            var r=p.Range.Duplicate;
            if(r.End-r.Start>10002) return "Paragraph exceeds the bounded text check; choose a smaller target.";
            bool exact=(bool?)c["exact"]??false;
            return TextMatches(exact?WordText(r.Text):r.Text,(string)c["text"],exact)?null:"Paragraph text differs from the plan.";
        }
        public static string PowerPointCheck(Ppt.Application app,JObject c)
        {
            ExecutionPlan.ValidateCheck(c,HostType.PowerPoint);
            var p=app.ActivePresentation; string kind=(string)c["kind"];
            if(kind=="slide_count") return p.Slides.Count==(int)c["count"]?null:"Slide count differs from the plan.";
            var slide=p.Slides[Index(c,"slide",1,p.Slides.Count)];
            var shape=slide.Shapes[Index(c,"shape",1,slide.Shapes.Count)];
            if(kind=="shape_bounds") return shape.Width>0 && shape.Height>0 && shape.Left>=0 && shape.Top>=0 && shape.Left+shape.Width<=p.PageSetup.SlideWidth+1 && shape.Top+shape.Height<=p.PageSetup.SlideHeight+1?null:"Shape extends outside the slide.";
            if(kind=="table_content")
            {
                if(shape.HasTable!=Microsoft.Office.Core.MsoTriState.msoTrue) return "Target shape is not a native PowerPoint table.";
                var table=shape.Table; var cells=(JArray)c["cells"];
                int rows=cells.Count, columns=((JArray)cells[0]).Count;
                if(table.Rows.Count!=rows || table.Columns.Count!=columns) return "PowerPoint table dimensions differ from the plan.";
                for(int row=1;row<=rows;row++) for(int column=1;column<=columns;column++)
                {
                    var textRange=table.Cell(row,column).Shape.TextFrame.TextRange;
                    if(textRange.Length>500 || !TextMatches(textRange.Text,(string)cells[row-1][column-1],true))
                        return "PowerPoint table cell content differs at row "+row+", column "+column+".";
                }
                return null;
            }
            if(shape.HasTextFrame!=Microsoft.Office.Core.MsoTriState.msoTrue) return "Target shape has no text frame.";
            var text=shape.TextFrame.TextRange;
            if(text.Length>10000) return "Shape exceeds the bounded text check.";
            return TextMatches(text.Text,(string)c["text"],(bool?)c["exact"]??false)?null:"Shape text differs from the plan.";
        }
    }
}
