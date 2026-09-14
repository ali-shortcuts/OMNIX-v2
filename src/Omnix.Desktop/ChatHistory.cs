using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using Omnix.Contracts;

namespace Omnix.Desktop
{
    public sealed class ChatSession
    {
        public string Id {get;set;}=Guid.NewGuid().ToString("N");
        public string Host {get;set;}
        public int Revision {get;set;}
        public DateTime UpdatedUtc {get;set;}=DateTime.UtcNow;
        public List<Message> Messages {get;set;}=new List<Message>();
        public override string ToString()
        {
            string title=Messages.FirstOrDefault()?.Text??"New chat";
            return UpdatedUtc.ToLocalTime().ToString("MMM d HH:mm")+" · "+title.Substring(0,Math.Min(42,title.Length)).Replace("\r"," ").Replace("\n"," ");
        }
    }
    public sealed class ChatArchive {public List<ChatSession> Sessions {get;set;}=new List<ChatSession>();}
    public static class ChatHistory
    {
        private static T Locked<T>(Func<T> action)
        {
            using(var mutex=new Mutex(false,"Local\\"+Wire.PipeName+".History")) {
                bool taken=false;
                try {
                    try{taken=mutex.WaitOne(3000);}catch(AbandonedMutexException){taken=true;}
                    if(!taken)throw new InvalidOperationException("Chat history is busy in another Office window.");
                    return action();
                }finally{if(taken)mutex.ReleaseMutex();}
            }
        }
        public static List<ChatSession> List(string host)=>Locked(()=>LocalData.Read<ChatArchive>("chats.dat").Sessions.Where(s=>s.Host==host).OrderByDescending(s=>s.UpdatedUtc).ToList());
        public static ChatSession Save(ChatSession session,List<Message> messages)=>Locked(()=>{
            session=Wire.Parse<ChatSession>(Wire.Json(session));
            var archive=LocalData.Read<ChatArchive>("chats.dat");
            var existing=archive.Sessions.FirstOrDefault(s=>s.Id==session.Id);
            // Concurrent edits branch into another session instead of overwriting another window's chat.
            if(existing!=null&&existing.Revision!=session.Revision)session=new ChatSession {Host=session.Host};
            else archive.Sessions.RemoveAll(s=>s.Id==session.Id);
            session.Messages=messages.Skip(Math.Max(0,messages.Count-100)).Select(m=>new Message {Role=m.Role,Text=m.Text}).ToList();
            while(session.Messages.Sum(m=>m.Text.Length)>180000)session.Messages.RemoveAt(0);
            session.Revision++;session.UpdatedUtc=DateTime.UtcNow;archive.Sessions.Add(session);
            archive.Sessions=archive.Sessions.OrderByDescending(s=>s.UpdatedUtc).Take(20).ToList();
            LocalData.Write("chats.dat",archive);return session;
        });
        public static void Delete(string id)=>Locked(()=>{
            var archive=LocalData.Read<ChatArchive>("chats.dat");archive.Sessions.RemoveAll(s=>s.Id==id);LocalData.Write("chats.dat",archive);return true;
        });
    }
}
