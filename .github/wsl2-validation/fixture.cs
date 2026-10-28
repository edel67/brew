using System;
using System.IO;
using System.Text;
public class Fixture {
 public static int Main(string[] args) {
  Console.OutputEncoding = new UTF8Encoding(false);
  string root = AppDomain.CurrentDomain.BaseDirectory;
  string source = args[Array.IndexOf(args, "--source") + 1];
  string query = args[0];
  File.AppendAllText(Path.Combine(root,"calls.txt"), query+":"+source+"\n");
  string[] config = File.ReadAllLines(Path.Combine(root,"config.txt"));
  uint code = 0;
  string mode = "valid";
  foreach(string line in config) {
   string[] pair=line.Split('=');
   if(pair[0]==query+":"+source) code=Convert.ToUInt32(pair[1],16);
   if(pair[0]=="mode") mode=pair[1];
  }
  Console.Error.WriteLine("native diagnostic café");
  if(query=="export") {
   string output=args[Array.IndexOf(args,"--output")+1];
   if(mode=="missing") { if(File.Exists(output)) File.Delete(output); }
   else File.WriteAllText(output,mode=="malformed" ? "invalid" : "{\"Sources\":[{\"Packages\":[{\"PackageIdentifier\":\"Example.App\"}]}]}",new UTF8Encoding(false));
  } else Console.WriteLine("Name                Id                  Version\n------------------------------------------------\nExample café        Example.App         1.0");
  return unchecked((int)code);
 }
}
