using System;
using System.Collections.Generic;
using System.Linq;

namespace Omnix.Desktop
{
    // Called exclusively on the Office UI thread. A complete snapshot is required
    // before pruning: a failed COM enumeration must never close healthy panes.
    public sealed class WindowWorkspaces<T> where T : class
    {
        private readonly Dictionary<string,T> items=new Dictionary<string,T>();
        private readonly Action<T> release;
        public WindowWorkspaces(Action<T> release){this.release=release;}
        public int Count => items.Count;
        public T GetOrCreate(string identity,Func<T> create)
        {
            T item;if(items.TryGetValue(identity,out item))return item;
            item=create();items.Add(identity,item);return item;
        }
        public void Prune(IEnumerable<string> live)
        {
            var keep=new HashSet<string>(live);
            foreach(string key in items.Keys.Where(k=>!keep.Contains(k)).ToArray()) {
                T item=items[key];items.Remove(key);release(item);
            }
        }
        public void Clear(){Prune(new string[0]);}
    }
}
