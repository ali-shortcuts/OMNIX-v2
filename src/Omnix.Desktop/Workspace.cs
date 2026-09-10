using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Win32;
using Omnix.Contracts;

namespace Omnix.Desktop
{
    public sealed class Workspace : UserControl,IDisposable
    {
        private readonly GatewayClient gateway;
        private readonly OfficeSelection office;
        private readonly string host;
        private Preferences preferences;
        private Provider editedProvider;
        private readonly Dictionary<string,string> keys=new Dictionary<string,string>();
        private readonly List<Message> messages=new List<Message>();
        private readonly List<SelectionSnapshot> retained=new List<SelectionSnapshot>();
        private SelectionSnapshot selection;
        private CancellationTokenSource running;
        private bool loaded,changing,disposed;
        private string imageData;
        private readonly TextBlock status=new TextBlock {Text="Ready",TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,8,0,0)};
        private readonly TextBlock destination=new TextBlock {Text="Choose your provider to get started",TextWrapping=TextWrapping.Wrap,Foreground=Brushes.SlateGray};
        private readonly StackPanel conversation=new StackPanel();
        private readonly ScrollViewer conversationScroll=new ScrollViewer {VerticalScrollBarVisibility=ScrollBarVisibility.Auto};
        private readonly TextBox prompt=new TextBox {AcceptsReturn=true,TextWrapping=TextWrapping.Wrap,MinHeight=72,MaxHeight=150,VerticalScrollBarVisibility=ScrollBarVisibility.Auto};
        private readonly TextBox captured=new TextBox {IsReadOnly=true,AcceptsReturn=true,TextWrapping=TextWrapping.Wrap,Height=90,VerticalScrollBarVisibility=ScrollBarVisibility.Auto};
        private readonly CheckBox include=new CheckBox {Content="Include captured selection in this request",Margin=new Thickness(0,8,0,8)};
        private readonly TextBlock imageLabel=new TextBlock {Text="No image attached",TextWrapping=TextWrapping.Wrap,Foreground=Brushes.SlateGray};
        private readonly ComboBox providers=new ComboBox {MinHeight=30};
        private readonly ComboBox model=new ComboBox {IsEditable=true,MinHeight=30,IsTextSearchEnabled=false};
        private readonly TextBox endpoint=new TextBox {MinHeight=30};
        private readonly PasswordBox key=new PasswordBox {MinHeight=30};
        private readonly TextBlock keyStatus=new TextBlock {Foreground=Brushes.SlateGray};
        private readonly CheckBox vision=new CheckBox {Content="This model supports image input",Margin=new Thickness(0,8,0,8)};
        private readonly ComboBox privacy=new ComboBox {ItemsSource=new[]{"Local only","Ask before sending","Cloud allowed"},MinHeight=30};
        private readonly TextBox draft=new TextBox {AcceptsReturn=true,TextWrapping=TextWrapping.Wrap,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,MinHeight=220};
        private readonly CheckBox asFormula=new CheckBox {Content="Apply as an Excel formula",Margin=new Thickness(0,10,0,10)};
        private readonly TextBox diagnostics=new TextBox {IsReadOnly=true,AcceptsReturn=true,TextWrapping=TextWrapping.Wrap,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,MinHeight=220};
        private readonly TabControl tabs=new TabControl();
        private readonly List<Button> guardedButtons=new List<Button>();

        public Workspace(object application,string hostName,string gatewayPath)
        {
            host=hostName; gateway=new GatewayClient(gatewayPath);
            if(application!=null) office=new OfficeSelection(application,hostName);
            FontFamily=new FontFamily("Segoe UI"); FontSize=13; Background=Brushes.White;
            var root=new Grid {Margin=new Thickness(16)};
            root.RowDefinitions.Add(new RowDefinition {Height=GridLength.Auto});
            root.RowDefinitions.Add(new RowDefinition());
            root.RowDefinitions.Add(new RowDefinition {Height=GridLength.Auto});
            var heading=new StackPanel {Margin=new Thickness(0,0,0,16)};
            heading.Children.Add(new TextBlock {Text="OMNIX",FontSize=25,FontWeight=FontWeights.SemiBold,Foreground=new SolidColorBrush(Color.FromRgb(25,48,80))});
            heading.Children.Add(new TextBlock {Text="Your AI workspace in "+host,Margin=new Thickness(0,4,0,8)});
            heading.Children.Add(destination); root.Children.Add(heading);
            Grid.SetRow(tabs,1); root.Children.Add(tabs);
            Grid.SetRow(status,2); root.Children.Add(status);
            Content=root;
            AddTab("Chat",CreateChat()); AddTab("Providers",CreateSettings()); AddTab("Review",CreateReview()); AddTab("Diagnostics",CreateDiagnostics());
            providers.SelectionChanged+=(s,e)=>{if(!changing)SwitchProvider();};
            Loaded+=async(s,e)=> {if(!loaded){loaded=true;await Run(Reload);}};
        }
        private static TextBlock Label(string value) => new TextBlock {Text=value,FontWeight=FontWeights.SemiBold,Margin=new Thickness(0,14,0,6),TextWrapping=TextWrapping.Wrap};
        private void AddTab(string title,UIElement content) => tabs.Items.Add(new TabItem {Header=title,Content=content,Padding=new Thickness(8,6,8,6)});
        private Button Button(string title,Action action,bool guard=true)
        {
            var button=new Button {Content=title,Padding=new Thickness(10,6,10,6),Margin=new Thickness(0,4,6,4)};
            button.Click+=(s,e)=>{try{action();}catch(Exception ex){Failure(ex);}};
            if(guard)guardedButtons.Add(button); return button;
        }
        private Button AsyncButton(string title,Func<Task> action) => Button(title,async()=>await Run(action));
        private UIElement CreateChat()
        {
            var grid=new Grid {Margin=new Thickness(0,12,0,0)};
            grid.RowDefinitions.Add(new RowDefinition {Height=GridLength.Auto}); grid.RowDefinitions.Add(new RowDefinition()); grid.RowDefinitions.Add(new RowDefinition {Height=GridLength.Auto});
            var context=new StackPanel();
            context.Children.Add(Button("Capture selection",Capture)); context.Children.Add(include);
            var preview=new Expander {Header="Selection preview",Content=captured,Margin=new Thickness(0,0,0,8)}; context.Children.Add(preview); grid.Children.Add(context);
            conversationScroll.Content=conversation; Grid.SetRow(conversationScroll,1); grid.Children.Add(conversationScroll);
            AddBubble("assistant","Choose a provider and model in Providers. Capture a selection when you want help with your document.");
            var compose=new StackPanel {Margin=new Thickness(0,12,0,0)};
            compose.Children.Add(imageLabel); compose.Children.Add(prompt);
            var buttons=new WrapPanel(); buttons.Children.Add(AsyncButton("Send",Send)); buttons.Children.Add(Button("Cancel",()=>running?.Cancel(),false));
            buttons.Children.Add(Button("Image",AttachImage)); buttons.Children.Add(Button("Clear image",()=>{imageData=null;imageLabel.Text="No image attached";}));
            buttons.Children.Add(Button("New chat",()=>{messages.Clear();conversation.Children.Clear();draft.Text="";status.Text="New chat started";}));
            compose.Children.Add(buttons); Grid.SetRow(compose,2); grid.Children.Add(compose); return grid;
        }
        private UIElement CreateSettings()
        {
            var panel=new StackPanel {Margin=new Thickness(0,8,8,0)};
            panel.Children.Add(Label("Provider")); panel.Children.Add(providers);
            panel.Children.Add(Button("Add compatible provider",()=>{
                CaptureFields(); var next=new Provider {Id=Guid.NewGuid().ToString("N"),Name="Custom provider "+(preferences.Providers.Count+1),Endpoint="https://example.com/v1"};
                preferences.Providers.Add(next); providers.Items.Refresh(); providers.SelectedItem=next;
            }));
            panel.Children.Add(Label("API base URL")); panel.Children.Add(endpoint);
            panel.Children.Add(Label("Model identifier")); panel.Children.Add(model);
            panel.Children.Add(new TextBlock {Text="Choose a discovered model or enter its exact identifier.",TextWrapping=TextWrapping.Wrap,Foreground=Brushes.SlateGray,Margin=new Thickness(0,5,0,0)});
            panel.Children.Add(Label("API key")); panel.Children.Add(key); panel.Children.Add(keyStatus);
            panel.Children.Add(Button("Remove saved key",()=>{if(editedProvider!=null){keys[editedProvider.Id]="";key.Clear();keyStatus.Text="Key will be removed when saved";}}));
            panel.Children.Add(vision);
            panel.Children.Add(Label("Privacy")); panel.Children.Add(privacy);
            panel.Children.Add(new TextBlock {Text="API keys are encrypted for your Windows account. Local only blocks remote providers. Model support and quotas are controlled by your provider.",TextWrapping=TextWrapping.Wrap,Foreground=Brushes.SlateGray,Margin=new Thickness(0,8,0,8)});
            var buttons=new WrapPanel(); buttons.Children.Add(AsyncButton("Save",Save)); buttons.Children.Add(AsyncButton("Reload",Reload));
            buttons.Children.Add(AsyncButton("Find models",FindModels)); buttons.Children.Add(AsyncButton("Test model",Probe)); panel.Children.Add(buttons);
            return new ScrollViewer {Content=panel,VerticalScrollBarVisibility=ScrollBarVisibility.Auto};
        }
        private UIElement CreateReview()
        {
            var panel=new StackPanel {Margin=new Thickness(0,8,8,0)};
            panel.Children.Add(Label("Review the proposed text"));
            panel.Children.Add(new TextBlock {Text="Edit the answer here before applying it. OMNIX changes only the captured selection after you confirm. Excel supports one cell; Word and PowerPoint support selected text.",TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,0,0,12)});
            panel.Children.Add(draft); if(host=="Excel")panel.Children.Add(asFormula);
            var actions=new WrapPanel(); actions.Children.Add(Button("Apply to selection",()=>{
                if(office==null)throw new InvalidOperationException("Open this workspace inside Office to edit a document.");
                if(MessageBox.Show("Apply the reviewed text to the captured selection?\n\n"+(selection?.Label??"No selection"),"Confirm document change",MessageBoxButton.OKCancel,MessageBoxImage.Question)!=MessageBoxResult.OK)return;
                office.Apply(selection,draft.Text,asFormula.IsChecked==true); status.Text="Change applied. Undo is available.";
            })); actions.Children.Add(Button("Undo OMNIX change",()=>{office?.Undo();status.Text="OMNIX change undone";}));
            actions.Children.Add(Button("Copy text",()=>Clipboard.SetText(draft.Text))); panel.Children.Add(actions);
            return new ScrollViewer {Content=panel,VerticalScrollBarVisibility=ScrollBarVisibility.Auto};
        }
        private UIElement CreateDiagnostics()
        {
            var panel=new StackPanel {Margin=new Thickness(0,8,8,0)};
            panel.Children.Add(Label("Connection and startup"));
            panel.Children.Add(new TextBlock {Text="This report records component status and error categories. It does not include API keys or document text.",TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,0,0,12)});
            panel.Children.Add(diagnostics); panel.Children.Add(AsyncButton("Refresh diagnostics",async()=>{
                var response=await gateway.CallAsync(new Request {Operation="ping"},running.Token);
                diagnostics.Text="OMNIX 4.0 preview\nHost: "+host+"\nProcess: "+(Environment.Is64BitProcess?"64-bit":"32-bit")+"\n"+response.Text+"\nNative Office pane: "+(office==null?"Preview only":"Created")+"\n\n";
                string log=Path.Combine(LocalData.Root,"diagnostics.log");
                if(File.Exists(log))diagnostics.AppendText(string.Join(Environment.NewLine,File.ReadLines(log).Reverse().Take(30).Reverse()));
            }));
            panel.Children.Add(new TextBlock {Text="Support: @Ali_silent0\nPreview build — real Office and restart acceptance must be recorded before production approval.",TextWrapping=TextWrapping.Wrap,Foreground=Brushes.SlateGray,Margin=new Thickness(0,12,0,0)});
            return new ScrollViewer {Content=panel,VerticalScrollBarVisibility=ScrollBarVisibility.Auto};
        }
        private void Capture()
        {
            if(office==null)throw new InvalidOperationException("Open this workspace inside Office to capture a selection.");
            selection=office.Capture(); retained.Add(selection); captured.Text=selection.Label+"\n\n"+selection.Text;
            status.Text="Selection captured. Enable inclusion if you want to send it to the model.";
        }
        private void CaptureFields()
        {
            if(editedProvider==null)return;
            editedProvider.Endpoint=endpoint.Text.Trim().TrimEnd('/'); editedProvider.Model=model.Text.Trim(); editedProvider.Vision=vision.IsChecked==true;
            if(key.Password.Length>0)keys[editedProvider.Id]=key.Password;
            key.Clear();
        }
        private void SwitchProvider()
        {
            CaptureFields(); editedProvider=providers.SelectedItem as Provider;
            if(editedProvider==null)return;
            endpoint.Text=editedProvider.Endpoint; model.ItemsSource=null; model.Text=editedProvider.Model; vision.IsChecked=editedProvider.Vision;
            keyStatus.Text=editedProvider.HasKey?"A key is saved. Leave blank to keep it.":"No saved key. Local providers may not need one.";
            preferences.Selected=editedProvider.Id;
        }
        private async Task Reload()
        {
            var response=await gateway.CallAsync(new Request {Operation="settings"},running.Token);
            SetPreferences(response.Settings); status.Text="Settings loaded";
        }
        private void SetPreferences(Preferences value)
        {
            changing=true;
            try { preferences=value;editedProvider=null;keys.Clear();key.Clear();providers.ItemsSource=preferences.Providers;providers.SelectedItem=preferences.Providers.First(p=>p.Id==preferences.Selected);privacy.SelectedItem=preferences.Privacy; }
            finally{changing=false;}
            SwitchProvider(); UpdateDestination();
        }
        private async Task Save()
        {
            if(preferences==null)throw new InvalidOperationException("Reload settings first.");
            CaptureFields(); preferences.Privacy=Convert.ToString(privacy.SelectedItem);
            var response=await gateway.CallAsync(new Request {Operation="save",Settings=preferences,NewKeys=new Dictionary<string,string>(keys)},running.Token);
            SetPreferences(response.Settings);status.Text=response.Text;
        }
        private void UpdateDestination() => destination.Text=editedProvider==null?"Choose a provider":editedProvider.Name+" · "+(string.IsNullOrEmpty(editedProvider.Model)?"No model selected":editedProvider.Model)+"\n"+preferences.Privacy;
        private Request Prepare(string operation)
        {
            if(editedProvider==null)throw new InvalidOperationException("Choose and save a provider first.");
            var request=new Request {Operation=operation,ProviderId=editedProvider.Id,ExpectedEndpoint=editedProvider.Endpoint,ExpectedModel=editedProvider.Model};
            var uri=new Uri(editedProvider.Endpoint);
            bool local=uri.IsLoopback;
            if(!local && preferences.Privacy=="Ask before sending") {
                string data=operation=="chat"?"This sends your chat"+(include.IsChecked==true?", captured selection":"")+(imageData==null?"":", and attached image")+".":"This sends a model discovery or synthetic connection test request.";
                request.CloudApproved=MessageBox.Show(data+"\n\nDestination: "+uri.GetLeftPart(UriPartial.Path)+"\nModel: "+editedProvider.Model,"Approve remote request",MessageBoxButton.OKCancel,MessageBoxImage.Question)==MessageBoxResult.OK;
                if(!request.CloudApproved)throw new OperationCanceledException();
            }
            return request;
        }
        private async Task FindModels()
        {
            await Save(); var response=await gateway.CallAsync(Prepare("models"),running.Token);
            string selected=model.Text;model.ItemsSource=response.Models;model.Text=selected;status.Text=response.Models.Count+" models found. You can also enter a model manually.";
        }
        private async Task Probe()
        {
            await Save();var response=await gateway.CallAsync(Prepare("probe"),running.Token);status.Text=response.Text;
        }
        private async Task Send()
        {
            string text=prompt.Text.Trim(); if(text.Length==0)return;
            if(text.Length>12000)throw new InvalidOperationException("Keep a single message under 12,000 characters.");
            await Save();var request=Prepare("chat");
            if(include.IsChecked==true && selection==null)throw new InvalidOperationException("Capture a selection before including it.");
            request.Context=include.IsChecked==true?selection.Text:null;
            request.ImageBase64=imageData;
            var outgoing=messages.Skip(Math.Max(0,messages.Count-10)).ToList();
            while(outgoing.Sum(m=>m.Text.Length)+text.Length>35000 && outgoing.Count>0)outgoing.RemoveAt(0);
            outgoing.Add(new Message {Role="user",Text=text});request.Messages=outgoing;
            status.Text="Waiting for "+editedProvider.Name+"…";
            var response=await gateway.CallAsync(request,running.Token);
            messages.Add(new Message {Role="user",Text=text});messages.Add(new Message {Role="assistant",Text=response.Text});
            if(messages.Count>100)messages.RemoveRange(0,messages.Count-100);
            AddBubble("user",text);AddBubble("assistant",response.Text);prompt.Clear();draft.Text=response.Text;status.Text="Answer received. Open Review to apply selected text.";
            conversationScroll.ScrollToEnd();
        }
        private void AddBubble(string role,string text)
        {
            var panel=new StackPanel();panel.Children.Add(new TextBlock {Text=role=="user"?"YOU":"OMNIX",FontSize=10,FontWeight=FontWeights.Bold,Foreground=Brushes.SlateGray,Margin=new Thickness(0,0,0,6)});
            panel.Children.Add(new TextBox {Text=text,IsReadOnly=true,TextWrapping=TextWrapping.Wrap,BorderThickness=new Thickness(0),Background=Brushes.Transparent,Padding=new Thickness(0)});
            conversation.Children.Add(new Border {Child=panel,Padding=new Thickness(12),Margin=new Thickness(0,0,0,10),CornerRadius=new CornerRadius(8),Background=new SolidColorBrush(role=="user"?Color.FromRgb(230,240,255):Color.FromRgb(245,247,250))});
            while(conversation.Children.Count>100)conversation.Children.RemoveAt(0);
        }
        private void AttachImage()
        {
            var dialog=new OpenFileDialog {Filter="Images|*.png;*.jpg;*.jpeg;*.bmp",Multiselect=false};if(dialog.ShowDialog()!=true)return;
            if(new FileInfo(dialog.FileName).Length>12*1024*1024)throw new InvalidOperationException("Choose an image smaller than 12 MB.");
            using(var source=System.Drawing.Image.FromFile(dialog.FileName)) {
                if((long)source.Width*source.Height>40000000)throw new InvalidOperationException("Choose an image below 40 megapixels.");
                double scale=Math.Min(1.0,1600.0/Math.Max(source.Width,source.Height));
                using(var bitmap=new System.Drawing.Bitmap(Math.Max(1,(int)(source.Width*scale)),Math.Max(1,(int)(source.Height*scale))))
                using(var draw=System.Drawing.Graphics.FromImage(bitmap))
                using(var bytes=new MemoryStream()) {
                    draw.DrawImage(source,0,0,bitmap.Width,bitmap.Height);bitmap.Save(bytes,System.Drawing.Imaging.ImageFormat.Png);
                    if(bytes.Length>2*1024*1024)throw new InvalidOperationException("The normalized image exceeds 2 MB. Choose a smaller image.");
                    imageData=Convert.ToBase64String(bytes.ToArray());imageLabel.Text="Image attached · "+bitmap.Width+" × "+bitmap.Height;
                }
            }
        }
        private async Task Run(Func<Task> action)
        {
            if(running!=null||disposed)return;
            running=new CancellationTokenSource();foreach(var b in guardedButtons)b.IsEnabled=false;
            try {await action();}
            catch(OperationCanceledException){status.Text="Request cancelled";}
            catch(Exception e){if(running.IsCancellationRequested)status.Text="Request cancelled";else Failure(e);}
            finally {running.Dispose();running=null;foreach(var b in guardedButtons)b.IsEnabled=true;}
        }
        private void Failure(Exception e) {status.Text=e.Message;LocalData.Log("WORKSPACE_ERROR",e);}
        public void Dispose()
        {
            disposed=true;running?.Cancel();foreach(var snapshot in retained)snapshot.Dispose();retained.Clear();imageData=null;keys.Clear();key.Clear();
        }
    }
}
