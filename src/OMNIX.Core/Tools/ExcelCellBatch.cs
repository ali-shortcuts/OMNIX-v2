using System;
using System.Collections.Generic;
using System.Globalization;
using Newtonsoft.Json.Linq;

namespace OMNIX.Core.Tools
{
    // Pure bounded plan: group adjacent cells only when their native write semantics agree.
    // Text and formulas NEVER share a batch. All Office access remains on the owner thread.
    public sealed class ExcelCellBatch
    {
        public int Row { get; private set; }
        public int Column { get; private set; }
        public string NumberFormat { get; private set; }
        public bool IsFormula { get; private set; }
        public object[,] Values { get; private set; }
        public int Count { get { return Values.GetLength(0); } }

        private static string Format(JToken token)
        {
            if(token.Type==JTokenType.String) return "@";
            var cell=token as JObject;
            if(cell==null) return "General";
            string format=(string)cell["numberFormat"];
            return string.IsNullOrWhiteSpace(format)?cell["date"]!=null?"yyyy-mm-dd":"General":format;
        }
        private static object Value(JToken token)
        {
            if(token.Type==JTokenType.Null) return null;
            if(token.Type==JTokenType.String) return (string)token;
            if(token.Type==JTokenType.Boolean) return (bool)token;
            if(token is JObject)
            {
                if(token["formula"]!=null) return (string)token["formula"];
                return DateTime.ParseExact((string)token["date"],"yyyy-MM-dd",CultureInfo.InvariantCulture).ToOADate();
            }
            return Convert.ToDouble(token,CultureInfo.InvariantCulture);
        }
        public static IList<ExcelCellBatch> Build(JObject plan)
        {
            ExcelTableBuilder.ValidatePlan(plan.ToString());
            var rows=(JArray)plan["rows"]; var headers=(JArray)plan["headers"];
            var batches=new List<ExcelCellBatch>();
            for(int column=0;column<headers.Count;column++)
            {
                for(int row=0;row<rows.Count;)
                {
                    JToken first=rows[row][column]; string format=Format(first);
                    bool formula=first is JObject && first["formula"]!=null;
                    int end=row+1;
                    while(end<rows.Count && Format(rows[end][column])==format &&
                        (rows[end][column] is JObject && rows[end][column]["formula"]!=null)==formula) end++;
                    var values=new object[end-row,1];
                    for(int i=row;i<end;i++) values[i-row,0]=Value(rows[i][column]);
                    batches.Add(new ExcelCellBatch {Row=row,Column=column,NumberFormat=format,IsFormula=formula,Values=values});
                    row=end;
                }
            }
            return batches;
        }
        public static object MatrixCell(object matrix,int row,int column,int rows,int columns)
        {
            var array=matrix as Array;
            if(array==null)
            {
                if(rows!=1 || columns!=1 || row!=0 || column!=0) throw new InvalidOperationException("Expected a bounded rectangular Office read-back.");
                return matrix;
            }
            if(array.Rank!=2 || array.GetLength(0)!=rows || array.GetLength(1)!=columns)
                throw new InvalidOperationException("Office read-back dimensions differ from the approved plan.");
            return array.GetValue(row+array.GetLowerBound(0),column+array.GetLowerBound(1));
        }
        public static void Verify(JObject plan,object values,object formulas,Func<ExcelCellBatch,bool?> hasFormula)
        {
            var rows=(JArray)plan["rows"]; int columns=((JArray)plan["headers"]).Count;
            foreach(var batch in Build(plan))
            {
                if(hasFormula(batch)!=batch.IsFormula) throw new InvalidOperationException("Office formula type differs from the approved batch.");
                for(int i=0;i<batch.Count;i++)
                {
                    int row=batch.Row+i; var token=rows[row][batch.Column];
                    object actual=MatrixCell(values,row,batch.Column,rows.Count,columns);
                    if(batch.IsFormula)
                    {
                        string formula=MatrixCell(formulas,row,batch.Column,rows.Count,columns) as string;
                        if(string.IsNullOrWhiteSpace(formula) || !formula.StartsWith("=",StringComparison.Ordinal))
                            throw new InvalidOperationException("Formula read-back is not a real formula.");
                        // Native acceptance separately verifies exact references and computed results.
                    }
                    else
                    {
                        var expected=new JValue(Value(token));
                        // Excel normalizes a literal empty string to an empty cell.
                        bool emptyText=token.Type==JTokenType.String && (string)token=="" && actual==null;
                        if(!emptyText && !Agent.OfficePostconditions.ValuesEqual(actual,expected))
                            throw new InvalidOperationException("Cell value/type differs from the approved plan at data row "+(row+1)+", column "+(batch.Column+1)+".");
                    }
                }
            }
        }
    }
}
