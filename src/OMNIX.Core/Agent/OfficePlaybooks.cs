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
