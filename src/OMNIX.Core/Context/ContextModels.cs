using System;

namespace OMNIX.Core.Context
{
    public enum HostType
    {
        Excel,
        Word,
        PowerPoint
    }

    /// <summary>
    /// Standardized document state produced by each host adapter (spec Section 3, Layer 3).
    /// Every host funnels its data into this shared structure so the rest of OMNIX is host-agnostic.
    /// </summary>
    public sealed class OfficeContext
    {
        public HostType Host { get; set; }

        public string DocumentName { get; set; }
        public string DocumentPath { get; set; }

        /// <summary>Excel: worksheet name. PowerPoint: "Slide 3". Word: section/headline summary.</summary>
        public string ContainerName { get; set; }

        /// <summary>Excel: "$A$1:$F$50". Word/PPT: first words of selection.</summary>
        public string SelectionAddress { get; set; }
        public string SelectionText { get; set; }

        public string ValuesPreview { get; set; }
        public string FormulasPreview { get; set; }
        public string NamedRanges { get; set; }
        public string HeadingsPreview { get; set; }
        public string ChartsInfo { get; set; }
        public string NotesPreview { get; set; }

        public int SlideCount { get; set; }
        public int CurrentSlideIndex { get; set; }
        public string SlideTitle { get; set; }

        public bool HasTrackChanges { get; set; }
        public int CommentCount { get; set; }

        public bool IsEmpty
        {
            get { return string.IsNullOrEmpty(DocumentName); }
        }

        /// <summary>Compact one-line summary for the context bar (spec Section 5).</summary>
        public string ContextBarText
        {
            get
            {
                if (IsEmpty) return "—";
                switch (Host)
                {
                    case HostType.Excel:
                        return "Excel: " + DocumentName + " / " + (ContainerName ?? "?")
                             + (string.IsNullOrEmpty(SelectionAddress) ? "" : " / " + SelectionAddress);
                    case HostType.Word:
                        return "Word: " + DocumentName
                             + (string.IsNullOrEmpty(SelectionAddress) ? "" : " / " + SelectionAddress);
                    case HostType.PowerPoint:
                        return "PowerPoint: " + DocumentName + " / Slide " + CurrentSlideIndex
                             + (string.IsNullOrEmpty(SelectionAddress) ? "" : " / " + SelectionAddress);
                    default:
                        return DocumentName;
                }
            }
        }
    }
}
