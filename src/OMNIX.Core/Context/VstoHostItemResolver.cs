using System;
using System.Reflection;

namespace OMNIX.Core.Context
{
    /// <summary>
    /// Resolves the host Application object from a VSTO ThisAddIn instance without relying on
    /// generated designer code. Strategy (Rule 12 — detect at runtime, never hard-code):
    ///   1) Reflection: find the IHostItemProvider inside the AddInBase chain and call
    ///      GetHostObject("...Interop.{Excel|Word|PowerPoint}.Application", cookie).
    ///   2) Fallback: GetActiveObject from the Running Object Table (the add-in lives in-process,
    ///      so this returns the hosting instance in normal single-instance scenarios).
    /// Every step is logged to startup-debug.log so first-load problems are immediately visible
    /// (spec 4.3 — first Startup log line happens before any other code).
    /// </summary>
    public static class VstoHostItemResolver
    {
        public static T ResolveApplication<T>(object thisAddIn, string progId) where T : class
        {
            // --- strategy 1: IHostItemProvider via reflection ---
            try
            {
                object provider = FindInstanceOfType(thisAddIn, "IHostItemProvider");
                if (provider != null)
                {
                    Type providerType = provider.GetType().GetInterface("IHostItemProvider");
                    if (providerType == null)
                    {
                        foreach (var it in provider.GetType().GetInterfaces())
                        {
                            if (it.Name == "IHostItemProvider") { providerType = it; break; }
                        }
                    }
                    if (providerType != null)
                    {
                        MethodInfo getHostObject = providerType.GetMethod("GetHostObject",
                            new[] { typeof(string), typeof(string) });
                        string cookie = FindStringMember(thisAddIn, "PrimaryCookie")
                                     ?? FindStringMember(thisAddIn, "Identifier")
                                     ?? "ThisAddIn";

                        if (getHostObject != null)
                        {
                            object app = getHostObject.Invoke(provider,
                                new object[] { typeof(T).FullName, cookie });
                            if (app != null)
                            {
                                Logging.Logger.Startup("Application resolved via IHostItemProvider.GetHostObject (" + typeof(T).Name + ")");
                                return (T)app;
                            }
                        }

                        // Some runtimes expose GetItem<T>(cookie) instead.
                        MethodInfo getItem = providerType.GetMethod("GetItem");
                        if (getItem != null)
                        {
                            try
                            {
                                object app = getItem.MakeGenericMethod(typeof(T)).Invoke(provider, new object[] { cookie });
                                if (app != null)
                                {
                                    Logging.Logger.Startup("Application resolved via IHostItemProvider.GetItem (" + typeof(T).Name + ")");
                                    return (T)app;
                                }
                            }
                            catch { }
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                Logging.Logger.Error("startup-debug", "Resolver strategy 1 failed", ex);
            }

            // --- strategy 2: GetActiveObject fallback ---
            try
            {
                object app = System.Runtime.InteropServices.Marshal.GetActiveObject(progId);
                if (app is T)
                {
                    Logging.Logger.Startup("Application resolved via GetActiveObject(\"" + progId + "\") fallback");
                    return (T)app;
                }
            }
            catch (Exception ex)
            {
                Logging.Logger.Error("startup-debug", "Resolver strategy 2 (GetActiveObject " + progId + ") failed", ex);
            }

            Logging.Logger.Startup("FAILED to resolve " + typeof(T).Name + " — add-in features that need the host object will be disabled.");
            return null;
        }

        private static object FindInstanceOfType(object root, string interfaceName)
        {
            for (Type t = root.GetType(); t != null && t != typeof(object); t = t.BaseType)
            {
                BindingFlags flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.DeclaredOnly;

                foreach (FieldInfo f in t.GetFields(flags))
                {
                    try
                    {
                        object v = f.GetValue(root);
                        if (v != null && ImplementsInterface(f.FieldType, interfaceName)) return v;
                    }
                    catch { }
                }
                foreach (PropertyInfo p in t.GetProperties(flags))
                {
                    try
                    {
                        if (!p.CanRead) continue;
                        MethodInfo getter = p.GetGetMethod(true);
                        if (getter == null || getter.GetParameters().Length != 0) continue;
                        object v = p.GetValue(root, null);
                        if (v != null && ImplementsInterface(p.PropertyType, interfaceName)) return v;
                    }
                    catch { }
                }
            }
            return null;
        }

        private static bool ImplementsInterface(Type type, string interfaceName)
        {
            if (type == null) return false;
            if (type.Name == interfaceName) return true;
            try
            {
                foreach (var it in type.GetInterfaces())
                    if (it.Name == interfaceName) return true;
            }
            catch { }
            return false;
        }

        private static string FindStringMember(object root, string name)
        {
            for (Type t = root.GetType(); t != null && t != typeof(object); t = t.BaseType)
            {
                BindingFlags flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.DeclaredOnly;
                foreach (PropertyInfo p in t.GetProperties(flags))
                {
                    if (p.Name == name && p.PropertyType == typeof(string) && p.CanRead)
                    {
                        try
                        {
                            object v = p.GetValue(root, null);
                            return v as string;
                        }
                        catch { }
                    }
                }
                foreach (FieldInfo f in t.GetFields(flags))
                {
                    if (f.Name == name && f.FieldType == typeof(string))
                    {
                        try { return f.GetValue(root) as string; }
                        catch { }
                    }
                }
            }
            return null;
        }
    }
}
