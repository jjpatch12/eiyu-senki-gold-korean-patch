using System;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;
public static class ESGDelta {
    static void Copy(Stream input, Stream output, long length) {
        if(length<0) throw new InvalidDataException("Invalid length");
        byte[] buffer=new byte[65536];
        while(length>0) { int n=input.Read(buffer,0,(int)Math.Min(length,buffer.Length));
            if(n==0) throw new EndOfStreamException(); output.Write(buffer,0,n);length-=n; }
    }
    public static void Apply(string source,string patch,string output,long expected) {
        using(var raw=File.OpenRead(patch))
        using(var gz=new GZipStream(raw,CompressionMode.Decompress))
        using(var reader=new BinaryReader(gz))
        using(var dst=new FileStream(output,FileMode.CreateNew))
        using(Stream src=String.IsNullOrEmpty(source) ? (Stream)new MemoryStream() : File.OpenRead(source)) {
            if(System.Text.Encoding.ASCII.GetString(reader.ReadBytes(8))!="ESGKR090") throw new InvalidDataException("Patch header");
            while(true) {
                byte op=reader.ReadByte(); if(op==69) break;
                if(op==67) {
                    long offset=reader.ReadInt64(),length=reader.ReadInt64();
                    if(offset<0 || length<0 || offset>src.Length-length || length>expected-dst.Length) throw new InvalidDataException("Copy bounds");
                    src.Position=offset;Copy(src,dst,length);
                } else if(op==76) {
                    long length=reader.ReadInt64();
                    if(length<0 || length>expected-dst.Length) throw new InvalidDataException("Literal bounds");
                    Copy(gz,dst,length);
                } else throw new InvalidDataException("Unknown operation");
            }
            if(dst.Length!=expected || gz.ReadByte()!=-1) throw new InvalidDataException("Output length");
        }
    }
    [DllImport("gdi32.dll",CharSet=CharSet.Unicode)] public static extern int AddFontResourceEx(string p,uint f,IntPtr r);
    [DllImport("gdi32.dll",CharSet=CharSet.Unicode)] public static extern bool RemoveFontResourceEx(string p,uint f,IntPtr r);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageTimeout(IntPtr h,uint m,UIntPtr w,string l,uint f,uint t,out UIntPtr r);
}
