using System;
using System.Runtime.InteropServices;
using Office = Microsoft.Office.Core;

namespace OMNIX.Excel.AddIn
{
    [ComVisible(true)]
    public sealed class OmnixRibbon : Office.IRibbonExtensibility
    {
        private readonly ThisAddIn _addIn;

        public OmnixRibbon(ThisAddIn addIn)
        {
            _addIn = addIn ?? throw new ArgumentNullException(nameof(addIn));
        }

        public string GetCustomUI(string ribbonId)
        {
            return @"<?xml version=""1.0"" encoding=""UTF-8""?>
<customUI xmlns=""http://schemas.microsoft.com/office/2009/07/customui"">
  <ribbon>
    <tabs>
      <tab id=""OMNIX.Tab"" label=""OMNIX"">
        <group id=""OMNIX.WorkspaceGroup"" label=""AI Workspace"">
          <button id=""OMNIX.OpenWorkspace"" label=""Open Workspace"" size=""large"" imageMso=""SmartArtInsert"" onAction=""OnOpenWorkspace"" />
          <button id=""OMNIX.Settings"" label=""Settings"" imageMso=""FileProperties"" onAction=""OnSettings"" />
        </group>
      </tab>
    </tabs>
  </ribbon>
</customUI>";
        }

        public void OnOpenWorkspace(Office.IRibbonControl control)
        {
            _addIn.ToggleWorkspace();
        }

        public void OnSettings(Office.IRibbonControl control)
        {
            _addIn.ShowSettings();
        }
    }
}
