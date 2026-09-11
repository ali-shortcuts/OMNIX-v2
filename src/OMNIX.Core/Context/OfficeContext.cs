using System;
using System.Collections.Generic;

namespace OMNIX.Core.Context
{
    public sealed class OfficeContext
    {
        public string Host { get; set; }
        public string DocumentName { get; set; }
        public string DocumentPath { get; set; }
        public string SelectionText { get; set; }
        public string ActiveContainer { get; set; }
        public IReadOnlyList<OfficeContextItem> Items { get; set; } = Array.Empty<OfficeContextItem>();
        public bool IsEmpty => string.IsNullOrWhiteSpace(SelectionText) && (Items == null || Items.Count == 0);
    }

    public sealed class OfficeContextItem
    {
        public string Kind { get; set; }
        public string Address { get; set; }
        public string Text { get; set; }
        public string Formula { get; set; }
        public string Metadata { get; set; }
    }
}
