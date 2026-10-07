using System;
using System.Linq;
using Newtonsoft.Json.Linq;
using OMNIX.Core.Agent;
using Word = Microsoft.Office.Interop.Word;

namespace OMNIX.Core.Tools
{
    // A bounded native paragraph operation, independent of the user's caret/selection.
    public static class WordParagraphWriter
    {
        public static int StyleId(string role)
        {
            if(role=="title") return (int)Word.WdBuiltinStyle.wdStyleTitle;
            if(role=="heading") return (int)Word.WdBuiltinStyle.wdStyleHeading1;
            if(role=="body") return (int)Word.WdBuiltinStyle.wdStyleBodyText;
            throw new ArgumentException("role must be title, heading or body.");
        }
        public static void Validate(JObject a)
        {
            if(a==null || a["paragraph"]==null || a["paragraph"].Type!=JTokenType.Integer ||
                (int)a["paragraph"]<1 || (int)a["paragraph"]>10000)
                throw new ArgumentException("An exact paragraph index between 1 and 10000 is required.");
            if(a["text"]==null || a["text"].Type!=JTokenType.String || string.IsNullOrWhiteSpace((string)a["text"]) ||
                ((string)a["text"]).Length>4000 || ((string)a["text"]).Any(char.IsControl))
                throw new ArgumentException("text must be one nonempty paragraph of at most 4000 characters without control characters.");
            if(a["expectedBefore"]==null || a["expectedBefore"].Type!=JTokenType.String || ((string)a["expectedBefore"]).Length>4000)
                throw new ArgumentException("expectedBefore must contain the exact inspected paragraph text (empty for a new paragraph).");
            StyleId((string)a["role"]);
            foreach(string name in new[]{"rtl","requireBlankDocument"})
                if(a[name]!=null && a[name].Type!=JTokenType.Boolean) throw new ArgumentException(name+" must be boolean.");
        }
        public static void Prepare(Word.Document doc,JObject a)
        {
            Validate(a);
            if(doc==null || doc.ReadOnly || doc.ProtectionType!=Word.WdProtectionType.wdNoProtection)
                throw new InvalidOperationException("The active Word document is unavailable, read-only or protected.");
            if((bool?)a["requireBlankDocument"]==true &&
                (doc.Content.End-doc.Content.Start>1 || doc.Content.Text!="\r" || doc.Tables.Count!=0 || doc.Shapes.Count!=0 || doc.InlineShapes.Count!=0))
                throw new InvalidOperationException("This template requires an empty main document. Existing content was retained; inspect and edit it instead.");
            int index=(int)a["paragraph"], count=doc.Paragraphs.Count;
            if(index>count+1) throw new ArgumentException("Paragraph gaps are not allowed; inspect the document before appending.");
            if(index==count+1)
            {
                if((string)a["expectedBefore"]!="") throw new ArgumentException("A new paragraph requires empty expectedBefore.");
                if(doc.Paragraphs[count].Range.Tables.Count>0)
                    throw new InvalidOperationException("The document ends inside a table; establish a separate body paragraph before appending.");
                return;
            }
            var range=doc.Paragraphs[index].Range;
            if(range.Tables.Count>0 || range.End-range.Start>4002)
                throw new InvalidOperationException("Target must be a bounded paragraph outside a table.");
            string actual=OfficePostconditions.WordText(range.Text);
            if(!OfficePostconditions.TextMatches(actual,(string)a["expectedBefore"],true) &&
                !OfficePostconditions.TextMatches(actual,(string)a["text"],true))
                throw new InvalidOperationException("The target paragraph changed after inspection. No replacement was applied.");
        }
        public static void Apply(Word.Application app,JObject a)
        {
            var doc=app.ActiveDocument; Prepare(doc,a);
            int index=(int)a["paragraph"]; string text=(string)a["text"], role=(string)a["role"];
            Word.UndoRecord undo=null;
            try
            {
                undo=app.UndoRecord; if(undo!=null) undo.StartCustomRecord("OMNIX paragraph.write");
                if(index==doc.Paragraphs.Count+1) doc.Range(doc.Content.End-1,doc.Content.End-1).InsertAfter("\r");
                var paragraph=doc.Paragraphs[index]; var range=paragraph.Range.Duplicate;
                range.End=range.End-1; range.Text=text;
                paragraph=doc.Paragraphs[index]; range=paragraph.Range;
                range.set_Style((object)StyleId(role));
                range.Font.Size=role=="title"?20:role=="heading"?14:12;
                range.Font.Bold=role=="body"?0:-1;
                bool rtl=(bool?)a["rtl"]??true;
                paragraph.Format.ReadingOrder=rtl?Word.WdReadingOrder.wdReadingOrderRtl:Word.WdReadingOrder.wdReadingOrderLtr;
                paragraph.Format.Alignment=role=="title"?Word.WdParagraphAlignment.wdAlignParagraphCenter:
                    rtl?Word.WdParagraphAlignment.wdAlignParagraphRight:Word.WdParagraphAlignment.wdAlignParagraphLeft;
                paragraph.Format.SpaceAfter=role=="title"?12:6;
                range.Select();
            }
            finally { if(undo!=null) { try {undo.EndCustomRecord();} catch {} } }
        }
    }
}
