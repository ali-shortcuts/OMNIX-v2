using System;
using System.IO;
using System.Reflection;
using System.Collections.Generic;
using System.Linq;
using Newtonsoft.Json.Linq;
using OMNIX.Core.Context;
namespace OMNIX.Core.Agent
{
    public static class OfficePlaybooks
    {
        private static string Read(string name)
        {
            using(var stream=typeof(OfficePlaybooks).Assembly.GetManifestResourceStream("OMNIX.Agent."+name))
            {
                if(stream==null) throw new InvalidOperationException("Missing Office playbook: "+name);
                using(var reader=new StreamReader(stream)) return reader.ReadToEnd();
            }
        }
        public static string Load(HostType host,string request)
        {
            string result=Read("contract.md")+"\n"+Read(host+".md");
            string q=(request??"").ToLowerInvariant();
            foreach(string term in new[]{"shop","sale","invoice","stock","gold","inventory","business","دکان","طلا","فروش","مشتری","انبار","دیتابیس","database"})
                if(q.Contains(term)) { result+="\n"+Read("business.md"); break; }
            return result;
        }
        public static string Template(JObject options,HostType host)
        {
            if(options==null) throw new ArgumentException("Template options are required.");
            string name=(string)options["name"];
            if(host==HostType.Excel) return Template(name,(string)options["sheet"],host);
            var catalog=JObject.Parse(Read("office_documents.json"));
            var template=catalog[host.ToString()]?[name??""] as JObject;
            if(template==null) throw new ArgumentException(host==HostType.Word?"Word templates: report, letter, meeting.":"PowerPoint templates: briefing, training, sales.");
            string title=(string)options["title"]??(string)template["title"];
            if(string.IsNullOrWhiteSpace(title) || title.Length>200 || title.Any(char.IsControl))
                throw new ArgumentException("A template title requires 1–200 characters without control characters.");
            bool rtl=true;
            if(options["rtl"]!=null) { if(options["rtl"].Type!=JTokenType.Boolean) throw new ArgumentException("rtl must be boolean."); rtl=(bool)options["rtl"]; }
            var steps=new JArray();
            if(host==HostType.Word)
            {
                AddParagraph(steps,1,title,"title",rtl,true);
                int paragraph=2;
                foreach(JObject section in (JArray)template["sections"])
                {
                    AddParagraph(steps,paragraph++,(string)section["heading"],"heading",rtl,false);
                    AddParagraph(steps,paragraph++,(string)section["body"],"body",rtl,false);
                }
            }
            else
            {
                if(options["startIndex"]==null || options["startIndex"].Type!=JTokenType.Integer || (int)options["startIndex"]<1 || (int)options["startIndex"]>9997)
                    throw new ArgumentException("PowerPoint templates require an inspected startIndex between 1 and 9997.");
                int index=(int)options["startIndex"], ordinal=0;
                foreach(JObject slide in (JArray)template["slides"])
                {
                    string slideTitle=ordinal++==0?title:(string)slide["title"], body=(string)slide["body"];
                    steps.Add(new JObject { ["id"]="slide-"+index, ["tool"]="insert_slide",
                        ["args"]=new JObject { ["index"]=index.ToString(System.Globalization.CultureInfo.InvariantCulture), ["title"]=slideTitle, ["body"]=body },
                        ["checks"]=new JArray(new JObject { ["kind"]="text",["slide"]=index,["shape"]=1,["text"]=slideTitle,["exact"]=true },
                            new JObject { ["kind"]="text",["slide"]=index,["shape"]=2,["text"]=body,["exact"]=true },
                            new JObject { ["kind"]="shape_bounds",["slide"]=index,["shape"]=1 },
                            new JObject { ["kind"]="shape_bounds",["slide"]=index,["shape"]=2 }) });
                    for(int shape=1;shape<=2;shape++)
                        steps.Add(new JObject { ["id"]="align-"+index+"-"+shape,["tool"]="execute_office_capability",
                            ["args"]=new JObject { ["capability"]="text.paragraph",["args"]=new JObject { ["slide"]=index,["shape"]=shape,["alignment"]=rtl?"right":"left" } },
                            ["checks"]=new JArray(new JObject { ["kind"]="text_alignment",["slide"]=index,["shape"]=shape,["alignment"]=rtl?"right":"left" }) });
                    index++;
                }
            }
            var plan=new JObject { ["steps"]=steps };
            var validator=new ExecutionPlan(); validator.Begin("template sample",true); validator.Submit(plan.ToString(),host);
            return plan.ToString(Newtonsoft.Json.Formatting.None);
        }
        private static void AddParagraph(JArray steps,int index,string text,string role,bool rtl,bool blank)
        {
            var args=new JObject { ["paragraph"]=index,["text"]=text,["expectedBefore"]="",["role"]=role,["rtl"]=rtl,["requireBlankDocument"]=blank };
            Tools.WordParagraphWriter.Validate(args);
            steps.Add(new JObject { ["id"]="paragraph-"+index,["tool"]="execute_office_capability",
                ["args"]=new JObject { ["capability"]="paragraph.write",["args"]=args },
                ["checks"]=new JArray(new JObject { ["kind"]="text",["paragraph"]=index,["text"]=text,["exact"]=true },
                    new JObject { ["kind"]="paragraph_style",["paragraph"]=index,["styleId"]=Tools.WordParagraphWriter.StyleId(role) },
                    new JObject { ["kind"]="paragraph_format",["paragraph"]=index,["fontSize"]=role=="title"?20:role=="heading"?14:12,
                        ["bold"]=role!="body",["rtl"]=rtl,["alignment"]=role=="title"?"center":rtl?"right":"left" }) });
        }
        public static string Template(string name,string sheet,HostType host)
        {
            if(host!=HostType.Excel) throw new ArgumentException("Typed templates currently available for Excel: gold, gold_shop, inventory, invoice. Use the host guide for other documents.");
            if(name!="gold" && name!="gold_shop" && name!="inventory" && name!="invoice") throw new ArgumentException("Available templates: gold, gold_shop, inventory, invoice.");
            if(string.IsNullOrWhiteSpace(sheet)) throw new ArgumentException("An exact new sheet name is required.");
            var plan=JObject.Parse(Read(name+".json"));
            if(name=="gold_shop")
            {
                var names=new Dictionary<string,string> {
                    {"@SALES@",sheet+" — فروش"}, {"@PRODUCTS@",sheet+" — محصولات"},
                    {"@CUSTOMERS@",sheet+" — مشتریان"}, {"@SUMMARY@",sheet+" — گزارش"}
                };
                foreach(var value in plan.Descendants().OfType<JValue>().Where(v=>v.Type==JTokenType.String).ToList())
                {
                    string text=(string)value;
                    var property=value.Parent as JProperty;
                    bool formula=property!=null && property.Name=="formula";
                    foreach(var pair in names) text=text.Replace(pair.Key,formula?pair.Value.Replace("'","''"):pair.Value);
                    value.Value=text;
                }
            }
            foreach(JObject step in (JArray)plan["steps"])
            {
                if(name!="gold_shop")
                {
                    step["args"]["sheet"]=sheet;
                    foreach(JObject check in (JArray)step["checks"]) check["sheet"]=sheet;
                }
                Tools.ExcelTableBuilder.ValidatePlan(step["args"].ToString());
                foreach(JObject check in (JArray)step["checks"]) ExecutionPlan.ValidateCheck(check,host);
            }
            return plan.ToString(Newtonsoft.Json.Formatting.None);
        }
    }
}
