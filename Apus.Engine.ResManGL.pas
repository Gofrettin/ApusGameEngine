﻿// OpenGL-based texture classes and texture manager
//
// Copyright (C) 2011 Ivan Polyacov, Apus Software (ivan@apus-software.com)
// This file is licensed under the terms of BSD-3 license (see license.txt)
// This file is a part of the Apus Game Engine (http://apus-software.com/engine/)

unit Apus.Engine.ResManGL;
interface
 uses Apus.Engine.API, Apus.Images, Apus.MyServis, Types, Apus.Engine.Resources;
{$IFDEF IOS} {$DEFINE GLES} {$DEFINE GLES11} {$DEFINE OPENGL} {$ENDIF}
{$IFDEF ANDROID} {$DEFINE GLES} {$DEFINE GLES20} {$DEFINE OPENGL} {$ENDIF}
type
 // Текстура OpenGL
 TGLTexture=class(TTexture)
 const
  MAX_LEVEL = 5;  // maximal number of supported mip level [0..MAX_LEVEL]
 var
  texname:cardinal;
  realWidth,realHeight:integer; // real dimensions of underlying texture object (can be larger than requested)
  filter:TTexFilter;
  procedure CloneFrom(src:TTexture); override;
  procedure SetAsRenderTarget; virtual;
  procedure Lock(miplevel:byte=0;mode:TlockMode=lmReadWrite;r:PRect=nil); override; // 0-й уровень - самый верхний
  procedure AddDirtyRect(rect:TRect;level:integer); override;
  function GetRawImage:TRawImage; override; // Создать RAW image и назначить его на верхний уровень текстуры (только когда текстура залочна!!!)
  procedure Unlock; override;
  destructor Destroy; override;
  function Describe:string;
  procedure SetFilter(filter:TTexFilter); override;
  procedure Dump(filename:string8=''); override;
 protected
  online:boolean; // true when image data is uploaded and ready to use (uv's are valid), false when local image data was modified and should be uploaded
  realData:array[0..MAX_LEVEL] of ByteArray; // sysmem instance of texture data
  fbo:cardinal; // framebuffer object (for a render target texture)
  rbo:cardinal; // renderbuffer object - for a render target texture with a depth buffer attached (but not for depth buffer textures)
  dirty:array[0..MAX_LEVEL,0..15] of TRect;
  dCount:array[0..MAX_LEVEL] of integer; // per each mip level
  procedure SetLabel; // submit name as label for OpenGL
  procedure UpdateFilter;
  procedure FreeData; virtual;
  procedure UploadData; virtual; // upload modified data (using dirty rects)
  procedure Bind; virtual;
  function GetTextureTarget:integer; virtual;
 end;

 TGLTextureArray=class(TGLTexture)
  constructor Create(numLayers:integer);
  procedure Lock(index:integer;miplevel:byte=0;mode:TLockMode=lmReadWrite;r:PRect=nil); reintroduce; overload;
  procedure Lock(miplevel:byte=0;mode:TLockMode=lmReadWrite;r:PRect=nil); overload; override; // treat mip level as array index for convenience
  procedure AddDirtyRect(index:integer;rect:TRect); overload; virtual;
  procedure Unlock; override;
  procedure Dump(filename:string8=''); override;
 protected
  layers:array of TGLTexture; // fake texture objects used to
  lockedLayer:integer;
  procedure FreeData; override;
  procedure UploadData; override;
  function GetTextureTarget:integer; override;
 end;

 TGLResourceManager=class(TInterfacedObject,IResourceManager)
  maxTextureSize,maxRTsize,maxRBsize:integer;

  constructor Create;
  destructor Destroy; override;

  function AllocImage(width,height:integer;PixFmt:TImagePixelFormat;
                flags:cardinal;name:String8):TTexture;
  procedure ResizeImage(var img:TTexture;newWidth,newHeight:integer);
  function Clone(img:TTexture):TTexture;
  procedure FreeImage(var image:TTexture);

  // Allocate texture array
  function AllocArray(width,height:integer;PixFmt:TImagePixelFormat;
                arraySize:integer;flags:cardinal;name:String8):TGLTextureArray;

  procedure MakeOnline(img:TTexture;stage:integer=0);
  procedure SetTexFilter(img:TTexture;filter:TTexFilter);

  function QueryParams(width,height:integer;format:TImagePixelFormat;usage:integer):boolean;

  // Вспомогательные функции (для отладки/получения инфы)
  function GetStatus(line:byte):string; // Формирует строки статуса

  // Создает дамп использования и распределения видеопамяти
  procedure Dump(st:string='');

 protected
  //CurTag:integer;
  //data:TObject;
  curTextures:array[0..3] of TGlTexture;
  texFilters:array[0..3] of TTexFilter;
  procedure FreeVidMem; // Освободить некоторое кол-во видеопамяти
  procedure FreeMetaTexSpace(n:integer); // Освободить некоторое пространство в указанной метатекстуре
  procedure AllocRenderTarget(tex:TGLTexture;flags:cardinal);
 end;

 var
  resourceManagerGL:TGLResourceManager;

 // Load image from file (TGA or JPG), result is expected in given pixel format or source pixel format
// function LoadFromFile(filename:string;format:TImagePixelFormat=ipfNone):TDxManagedTexture;

implementation
 uses Apus.CrossPlatform, Apus.EventMan, SysUtils, Apus.GfxFormats,
   {$IFDEF MSWINDOWS}dglOpenGl{$ENDIF}
   {$IFDEF LINUX}dglOpenGL{$ENDIF}
   {$IFDEF IOS}gles11,glext{$ENDIF}
   {$IFDEF ANDROID}gles20{$ENDIF}
   ;

{ Принцип работы: по возможности текстуры создаются как обычные
  буферы данных в памяти. По вызову MakeOnline данные перебрасываются
  в текстуры GL. Обычно это происходит непосредственно перед отрисовкой
  (и в потоке отрисовки), т.о. избегаем проблем многопоточности.
}

const
 {$IFDEF GLES11}
 MAX_TEX_SIZE = 1024;
 {$ELSE}
 MAX_TEX_SIZE = 2048;
 {$ENDIF}

var
 mainThreadId:TThreadID;
 cSect:TMyCriticalSection; // TODO: зачем? Нет глобальных данных, нуждающихся в защите
 lastErrorTime:int64;
 errorTr:integer;

procedure CheckForGLError(msg:string); //inline;
var
 error:cardinal;
 t:int64;
begin
 error:=glGetError;
 if error<>GL_NO_ERROR then try
  t:=MyTickCount;
  if t<lastErrorTime+1000 then inc(errorTr)
   else errorTr:=0;
  if errorTr<5 then begin
   lastErrorTime:=t;
   ForceLogMessage('GLI Error ('+msg+') '+inttostr(error)+' '+GetCallStack);
  end;
 except
 end;
end;

procedure GetGLformat(ipf:TImagePixelFormat;out format,subFormat,internalFormat:cardinal);
begin
 case ipf of
  {$IFNDEF GLES}
  ipf8Bit:begin
   internalFormat:=4;
   format:=GL_COLOR_INDEX;
   subFormat:=GL_UNSIGNED_BYTE;
  end;
  ipfRGB:begin
   internalFormat:=GL_RGB;
   format:=GL_BGR;
   subFormat:=GL_UNSIGNED_BYTE;
  end;
  ipfARGB:begin
   internalFormat:=GL_RGBA;
   format:=GL_BGRA;
   subFormat:=GL_UNSIGNED_BYTE;
  end;
  ipfXRGB:begin
   internalFormat:=GL_RGB;
   format:=GL_BGRA;
   subFormat:=GL_UNSIGNED_BYTE;
  end;
  ipfMono8:begin
   internalFormat:=GL_R8;
   format:=GL_RED;
   subFormat:=GL_UNSIGNED_BYTE;
  end;
  ipfMono8u:begin
   internalFormat:=GL_R8UI;
   format:=GL_RED_INTEGER;
   subFormat:=GL_UNSIGNED_BYTE;
  end;
  ipfMono16:begin
   internalFormat:=GL_R16;
   format:=GL_RED;
   subFormat:=GL_UNSIGNED_SHORT;
  end;
  ipfMono16s:begin
   internalFormat:=GL_R16_SNORM;
   format:=GL_RED_INTEGER;
   subFormat:=GL_SHORT;
  end;
  ipfMono16i:begin
   internalFormat:=GL_R16I;
   format:=GL_RED_INTEGER;
   subFormat:=GL_SHORT;
  end;
  ipfMono32f:begin
   internalFormat:=GL_R32F;
   format:=GL_RED;
   subFormat:=GL_FLOAT;
  end;
  ipfDuo32f:begin
   internalFormat:=GL_RG32F;
   format:=GL_RG;
   subFormat:=GL_FLOAT;
  end;
  ipfDuo8:begin
   internalFormat:=GL_RG8;
   format:=GL_RG;
   subFormat:=GL_UNSIGNED_BYTE;
  end;
  ipf565:begin
   internalFormat:=GL_RGB5;
   format:=GL_RGB;
   subFormat:=GL_UNSIGNED_SHORT_5_6_5;
  end;
  ipf1555:begin
   internalFormat:=GL_RGB5;
   format:=GL_RGBA;
   subFormat:=GL_UNSIGNED_SHORT_5_5_5_1;
  end;
  ipf4444:begin
   internalFormat:=GL_RGBA4;
   format:=GL_RGBA;
   subFormat:=GL_UNSIGNED_SHORT_4_4_4_4_REV;
  end;
  ipf4444r:begin
   internalFormat:=GL_RGBA4;
   format:=GL_RGBA;
   subFormat:=GL_UNSIGNED_SHORT_4_4_4_4;
  end;
  ipfDXT1:begin
   internalFormat:=GL_COMPRESSED_RGBA_S3TC_DXT1_EXT;
   format:=GL_COMPRESSED_TEXTURE_FORMATS;
  end;
  ipfDXT3:begin
   internalFormat:=GL_COMPRESSED_RGBA_S3TC_DXT3_EXT;
   format:=GL_COMPRESSED_TEXTURE_FORMATS;
  end;
  ipfDXT5:begin
   internalFormat:=GL_COMPRESSED_RGBA_S3TC_DXT5_EXT;
   format:=GL_COMPRESSED_TEXTURE_FORMATS;
  end;
  ipfA4:begin
   internalFormat:=GL_ALPHA4;
   format:=GL_ALPHA;
   subFormat:=GL_UNSIGNED_BYTE;
  end;
  ipfL4A4:begin
   internalFormat:=GL_LUMINANCE4_ALPHA4;
   format:=GL_LUMINANCE_ALPHA;
   subFormat:=GL_UNSIGNED_BYTE;
  end;
  ipfA8:begin
   internalFormat:=GL_ALPHA8;
   format:=GL_ALPHA;
   subFormat:=GL_UNSIGNED_BYTE;
  end;
  {$ENDIF}
  {$IFDEF GLES}
  ipfARGB:begin
   if pos('TEXTURE_FORMAT_BGRA8888',GLES_Extensions)>0 then begin
    internalFormat:=GL_BGRA;
    format:=GL_BGRA;
   end else begin
    internalFormat:=GL_RGBA;
    format:=GL_RGBA;
   end;
   subFormat:=GL_UNSIGNED_BYTE;
  end;
  ipfRGB:begin
   internalFormat:=GL_RGB;
   format:=GL_RGB;
   subFormat:=GL_UNSIGNED_BYTE;
  end;
  ipf565:begin
   internalFormat:=GL_RGB;
   format:=GL_RGB;
   subFormat:=GL_UNSIGNED_SHORT_5_6_5;
  end;
  ipf1555:begin
   internalFormat:=GL_RGBA;
   format:=GL_RGBA;
   subFormat:=GL_UNSIGNED_SHORT_5_5_5_1;
  end;
  {$IFDEF IOS}
  ipf4444:begin
   internalFormat:=GL_RGBA;
   format:=GL_RGBA;
   subFormat:=GL_UNSIGNED_SHORT_4_4_4_4_REV;
  end;
  {$ENDIF}
  ipf4444r:begin
   internalFormat:=GL_RGBA;
   format:=GL_RGBA;
   subFormat:=GL_UNSIGNED_SHORT_4_4_4_4;
  end;
  ipfPVRTC:begin
   internalFormat:=GL_COMPRESSED_RGBA_PVRTC_4BPPV1_IMG;
   format:=GL_COMPRESSED_TEXTURE_FORMATS;
  end;
  ipfA8:begin
   internalFormat:=GL_ALPHA;
   format:=GL_ALPHA;
   subFormat:=GL_UNSIGNED_BYTE;
  end;
  {$ENDIF}
  else
   raise EError.Create('Unsupported pixel format: '+PixFmt2Str(ipf));
 end;
end;

{ TGLTextureArray }

procedure TGLTextureArray.AddDirtyRect(index: integer; rect: TRect);
begin

end;

constructor TGLTextureArray.Create(numLayers: integer);
var
 i:integer;
begin
 SetLength(layers,numLayers);
 for i:=0 to numLayers-1 do
  layers[i]:=TGLTexture.Create;
end;


procedure TGLTextureArray.Dump(filename:string8);
var
 layer,itemSize:integer;
 texData,data:ByteArray;
 image:TRawImage;
begin
 if filename='' then filename:='tex_'+name+'_';
 if texname=0 then begin
   SaveFile(filename+'.tex','Not allocated');
   exit;
  end;
 Bind;
 itemSize:=width*height*4;
 SetLength(texData,itemSize*length(layers));
 glGetTexImage(GetTextureTarget,0,GL_BGRA,GL_UNSIGNED_INT_8_8_8_8_REV,@texData[0]);
 image:=TBitmapImage.Create(width,height,ipfARGB);
 for layer:=0 to high(layers) do begin
  image.data:=@texData[itemSize*layer];
  image.data:=@(layers[layer].realData[0,0]);
  data:=SavePNG(image);
  SaveFile(filename+inttostr(layer)+'.png',data);
 end;
 image.Free;
end;

procedure TGLTextureArray.FreeData;
begin
 inherited;
end;

function TGLTextureArray.GetTextureTarget: integer;
begin
 result:=GL_TEXTURE_2D_ARRAY;
end;

procedure TGLTextureArray.Lock(index:integer; miplevel:byte; mode:TlockMode; r:PRect);
begin
 inc(locked);
 layers[index].Lock(mipLevel,mode,r);
 data:=layers[index].data;
 pitch:=layers[index].pitch;
 lockedLayer:=index;
end;

procedure TGLTextureArray.Lock(miplevel:byte=0;mode:TlockMode=lmReadWrite;r:PRect=nil);
begin
 Lock(mipLevel,0,mode,r);
end;

procedure TGLTextureArray.Unlock;
begin
 layers[lockedLayer].Unlock;
 dec(locked);
end;

procedure TGLTextureArray.UploadData;
var
 needInit:boolean;
 format,subformat,internalFormat,error:cardinal;
 i,bpp,z,depth,level:integer;
begin
  needInit:=false;
  if locked>0 then raise EWarning.Create('MO for a locked texture: '+name);

  if texname=0 then begin // allocate texture name
   glGenTextures(1,@texname);
   CheckForGLError('11');
   Bind;
   SetLabel;
   CheckForGLError('12');
   needInit:=true;
  end;

  // Upload texture data
  GetGLFormat(PixelFormat,format,subFormat,internalFormat);
  depth:=length(layers);
  if format=GL_COMPRESSED_TEXTURE_FORMATS then begin
   for z:=0 to depth-1 do
    for level:=0 to MAX_LEVEL do
     if length(realData[level])>0 then
      glCompressedTexImage3D(GL_TEXTURE_2D_ARRAY,level,internalFormat,realwidth,realheight,depth,0,
       length(layers[z].realData[level]),@realData[level,0]);
  end else begin
   {$IFNDEF GLES}
   if needInit then begin  // Specify texture size and pixel format
    glTexImage3D(GL_TEXTURE_2D_ARRAY,0,internalFormat,realwidth,realheight,depth,0,
      format,subFormat,nil);
    CheckForGLError('13');
    UpdateFilter;
   end;
    // Upload texture data
    glPixelStorei(GL_UNPACK_ROW_LENGTH,realWidth);
    CheckForGLError('14');
    bpp:=pixelSize[pixelFormat] div 8;
    for z:=0 to depth-1 do
     with layers[z] do
      for level:=0 to MAX_LEVEL do begin
       for i:=0 to dCount[level]-1 do
        with dirty[level,i] do
         glTexSubImage3D(GL_TEXTURE_2D_ARRAY,level,Left,Top,z,right-left+1,bottom-top+1,1,
            format,subFormat,@realData[level,(left+top*realWidth)*bpp]);
       dCount[level]:=0;
      end;
    CheckForGLError('15');
   {$ELSE}
   // GLES doesn't support UNPACK_ROW_LENGTH so it's not possible to upload just a portion of
   // the source texture data
   NotSupported('');
{   for z:=0 to depth-1 do
    with layers[z] do begin
    if format=GL_RGBA then ConvertColors32(data,realwidth*realheight);
    if format=GL_RGB then ConvertColors24(data,realwidth*realheight);
    glTexImage3D(GL_TEXTURE_2D_ARRAY,0,internalFormat,realwidth,realheight,1,0,format,subFormat,data);
   end;}
   CheckForGLError('16');
   {$ENDIF}
   if HasFlag(tfAutoMipMap) and (GL_VERSION_3_0 or GL_ARB_framebuffer_object) then begin
    glGenerateMipmap(GL_TEXTURE_2D_ARRAY);
   end;

   if HasFlag(tfClamped) then begin
    glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
   end else begin
    glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_WRAP_S,GL_REPEAT);
    glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_WRAP_T,GL_REPEAT);
   end;
   CheckForGLError('17');
  end;
  online:=true;
end;

{ TGLTexture }

procedure TGLTexture.Bind;
begin
 glBindTexture(GetTextureTarget,texname);
end;

procedure TGLTexture.CloneFrom(src: TTexture);
begin
 inherited;
end;

function TGLTexture.Describe: string;
begin
 if self is TGLTexture then
  result:=Format('GLTexture(%8x):%s w=%d h=%d m=%d c=%x l=%d o=%d tn=%d fbo=%d dC=%d',
    [cardinal(self),name,width,height,mipmaps,caps,byte(locked),byte(online),texname,fbo,dCount[0]])
 else
  result:='Not a GL Texture at: '+inttohex(cardinal(self),8);
end;

destructor TGLTexture.Destroy;
var
 t:TTexture;
begin
 if texName<>0 then begin
  t:=self;
  resourceManagerGL.FreeImage(t);
 end else
  inherited;
end;

procedure TGLTexture.Dump(filename:string8);
var
 data:ByteArray;
 image:TRawImage;
begin
 if filename='' then filename:='tex'+name+'.png';
 if texname=0 then begin
  SaveFile(filename,'Not allocated');
  exit;
 end;
 image:=TBitmapImage.Create(width,height,ipfARGB);
 Bind;
 glGetTexImage(GetTextureTarget,0,GL_BGRA,GL_UNSIGNED_INT_8_8_8_8,image.data);
 data:=SavePNG(image);
 image.Free;
 SaveFile(filename,data);
end;

procedure TGLTexture.FreeData;
begin

end;

function TGLTexture.GetRawImage: TRawImage;
begin
 result:=TRawImage.Create;
 result.width:=width;
 result.height:=height;
 result.PixelFormat:=PixelFormat;
 result.data:=data;
 result.pitch:=pitch;
 result.paletteFormat:=palNone;
 result.palette:=nil;
 result.palSize:=0;
end;

function TGLTexture.GetTextureTarget: integer;
begin
 result:=GL_TEXTURE_2D;
end;

procedure TGLTexture.Lock(miplevel:byte=0;mode:TlockMode=lmReadWrite;r:PRect=nil);
var
 size:integer;
 lockRect:TRect;
begin
 ASSERT(mipLevel<=MAX_LEVEL);
 if HasFlag(tfNoRead) then
   raise EWarning.Create('Can''t lock texture '+name+' for reading');
 if HasFlag(tfNoWrite) and (mode<>lmReadOnly) then
   raise EWarning.Create('Can''t lock texture '+name+' for writing');
 if r=nil then lockRect:=Rect(0,0,(width-1) shr mipLevel,(height-1) shr mipLevel) // full rect
  else lockRect:=r^;
 if (mode=lmCustomUpdate) and (r<>nil) then
  raise EWarning.Create('GLTex: for custom update must lock full surface');
 EnterCriticalSection(cSect);
 try
  mipmaps:=max2(mipmaps,mipLevel);
  if length(realdata[mipLevel])=0 then begin // alloc another mip level
   size:=max2(width shr mipLevel,1)*max2(height shr mipLevel,1); // number of texels
   size:=size*pixelSize[pixelFormat] div 8;
   SetLength(realdata[mipLevel],size);
  end;
  pitch:=max2(width shr mipLevel,1)*pixelSize[pixelFormat] shr 3;
  if r=nil then data:=@realData[mipLevel,0]
   else data:=@realData[mipLevel,lockRect.left*PixelSize[pixelFormat] shr 3+lockRect.Top*pitch];
  inc(locked);

  if mode=lmReadWrite then begin
   online:=false;
   AddDirtyRect(lockRect,mipLevel);
  end;
 finally
  LeaveCriticalSection(cSect);
 end;
end;

procedure TGLTexture.AddDirtyRect(rect:TRect;level:integer);
var
 n:integer;
begin
 online:=false;
 n:=dCount[level];
 if n<high(dirty[level]) then begin
  dirty[level,n]:=rect;
  inc(dCount[level]);
 end else begin
  // Too many rects - invalidate all
  dCount[level]:=1;
  dirty[level,0]:=Types.Rect(0,0,width-1,height-1);
 end;
end;


procedure TGLTexture.SetAsRenderTarget;
begin
 Assert(HasFlag(tfRenderTarget));
 {$IFDEF GLES11}
 glBindFramebufferOES(GL_FRAMEBUFFER_OES,fbo);
 {$ENDIF}
 {$IFDEF GLES20}
 glBindFramebuffer(GL_FRAMEBUFFER,fbo);
 {$ENDIF}
 {$IFNDEF GLES}
 if GL_ARB_framebuffer_object then
  glBindFramebuffer(GL_FRAMEBUFFER,fbo)
 else if GL_EXT_framebuffer_object then
  glBindFramebufferEXT(GL_FRAMEBUFFER,fbo)
 else
  raise EError.Create('SART: Render target not supported');
 {$ENDIF}
 CheckForGLError('SART:'+Describe);
end;

procedure TGLTexture.SetFilter(filter:TTexFilter);
 begin
  self.filter:=filter;
  if texname<>0 then UpdateFilter;
 end;

procedure TGLTexture.SetLabel;
var
 lab:String8;
begin
 if (name<>'') and (@glObjectLabel<>nil) then begin
  lab:=name;
  glObjectLabel(GL_TEXTURE,texname,length(lab),@lab[1]);
 end;
end;

procedure TGLTexture.Unlock;
begin
 EnterCriticalSection(cSect);
 try
  ASSERT(locked>0,'Texture not locked: '+name);
  dec(locked);
 finally
  LeaveCriticalSection(cSect);
 end;
end;

procedure TGLTexture.UpdateFilter;
var
 fMin,fMax:integer;
 target,aTex:GLInt;
begin
 if texname=0 then exit;
 case filter of
  fltUndefined:exit;
  fltNearest:begin
   fMin:=GL_NEAREST;
   fMax:=GL_NEAREST;
  end;
  fltBilinear:begin
   if mipmaps>0 then begin
    fMin:=GL_LINEAR_MIPMAP_NEAREST;
    //fMin:=GL_LINEAR;
    fMax:=GL_LINEAR;
   end else begin
    fMin:=GL_LINEAR;
    fMax:=GL_LINEAR;
   end;
  end;
  fltTrilinear:begin
   if mipmaps>0 then begin
    fMin:=GL_LINEAR_MIPMAP_LINEAR;
    fMax:=GL_LINEAR;
   end else begin
    fMin:=GL_LINEAR;
    fMax:=GL_LINEAR;
   end;
  end;
 end;
 if @glTextureParameteri<>nil then begin
  // GL 4.5 mode
  glTextureParameteri(texname,GL_TEXTURE_MIN_FILTER,fMin);
  glTextureParameteri(texname,GL_TEXTURE_MAG_FILTER,fMax);
 end else
 if @glTextureParameteriEXT<>nil then begin
  // EXT_direct_state_access mode
  target:=GetTextureTarget;
  glTextureParameteriEXT(texname,target,GL_TEXTURE_MIN_FILTER,fMin);
  glTextureParameteriEXT(texname,target,GL_TEXTURE_MAG_FILTER,fMax);
 end else begin
  // 4.4- compatibility mode
  target:=GetTextureTarget;
  glGetIntegerv(GL_ACTIVE_TEXTURE,@aTex);
  if aTex<>GL_TEXTURE0+9 then glActiveTexture(GL_TEXTURE0+9);
  glBindTexture(target,texname);
  glTexParameteri(target,GL_TEXTURE_MIN_FILTER,fMin);
  glTexParameteri(target,GL_TEXTURE_MAG_FILTER,fMax);
  CheckForGLError('16');
  if aTex<>GL_TEXTURE0+9 then glActiveTexture(aTex);
 end;
end;

procedure TGLTexture.UploadData;
var
 needInit:boolean;
 format,subformat,internalFormat,error:cardinal;
 i,bpp,level:integer;
begin
  needInit:=false;
  if locked>0 then raise EWarning.Create('MO for a locked texture: '+name);
  if texname=0 then begin // allocate texture name
   glGenTextures(1,@texname);
   CheckForGLError('11');
   glBindTexture(GL_TEXTURE_2D, texname);
   SetLabel;
   CheckForGLError('12');
   needInit:=true;
  end;

  GetGLFormat(PixelFormat,format,subFormat,internalFormat);
  // Upload texture data
  if format=GL_COMPRESSED_TEXTURE_FORMATS then begin
   for level:=0 to MAX_LEVEL do
    if length(realData[level])>0 then
     glCompressedTexImage2D(GL_TEXTURE_2D,level,internalFormat,realwidth,realheight,0,
       length(realData[level]),@realData[level,0]);
  end else begin
   {$IFNDEF GLES}
   if needInit then begin  // Specify texture size and pixel format
    for level:=0 to MAX_LEVEL do
     if length(realData[level])>0 then
      glTexImage2D(GL_TEXTURE_2D,level,internalFormat,
        max2(realwidth shr level,1),max2(realheight shr level,1),0,format,subFormat,nil);
    CheckForGLError('13');
    UpdateFilter;
   end;
   for level:=0 to MAX_LEVEL do
    if dCount[level]>0 then begin
     // Upload texture data
     glPixelStorei(GL_UNPACK_ROW_LENGTH,realWidth shr level);
     CheckForGLError('14');
     bpp:=pixelSize[pixelFormat] div 8;
     for i:=0 to dCount[level]-1 do
      with dirty[level,i] do
       glTexSubImage2D(GL_TEXTURE_2D,level,Left,Top,right-left+1,bottom-top+1,
          format,subFormat,@realData[level,(left+top*realWidth)*bpp]);
     CheckForGLError('15');
     dCount[level]:=0;
    end;
   // Set level limit - otherwise texture sampler will produce black
   glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAX_LEVEL,mipmaps);
   {$ELSE}
   // GLES doesn't support UNPACK_ROW_LENGTH so it's not possible to upload just a portion of
   // the source texture data
   if format=GL_RGBA then ConvertColors32(data,realwidth*realheight);
   if format=GL_RGB then ConvertColors24(data,realwidth*realheight);
   glTexImage2D(GL_TEXTURE_2D,0,internalFormat,realwidth,realheight,0,format,subFormat,data);
   CheckForGLError('16');
   {$ENDIF}
   if HasFlag(tfAutoMipMap) and (GL_VERSION_3_0 or GL_ARB_framebuffer_object) then begin
    glGenerateMipmap(GL_TEXTURE_2D);
   end;

   if HasFlag(tfClamped) then begin
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
   end else begin
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_REPEAT);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_REPEAT);
   end;
   CheckForGLError('17');
  end;
  online:=true;
end;

procedure EventHandler(event:TEventStr;tag:TTag);
var
 tex:TTexture;
begin
 if SameText(event,'GLImages\DeleteTexture') then begin
  tex:=TTexture(UIntPtr(tag));
  resourceManagerGL.FreeImage(tex);
 end;
end;

{ TGLResourceManager }

procedure TGLResourceManager.AllocRenderTarget(tex:TGLTexture;flags:cardinal);
var
 format,SubFormat,internalFormat:cardinal;
 status:cardinal;
 prevFramebuffer:GLint;
 renderBuffer:GLUint;
begin
 begin
  LogMessage(sysUtils.Format('AllocImage RT %dx%d %d (%s)',[tex.width,tex.height,flags,tex.name]));
  if max2(tex.width,tex.height)>maxRTsize then raise EWarning.Create('AI: RT texture too large');
  {$IFDEF GLES}
  {$IFDEF GLES11}
  width:=GetPow2(width);
  height:=GetPow2(height);
  glGenFramebuffersOES(1,@tex.fbo);
  glBindFramebufferOES(GL_FRAMEBUFFER_OES,tex.fbo);
  {$ELSE}
  glGenFramebuffers(1,@tex.fbo);
  glBindFramebuffer(GL_FRAMEBUFFER,tex.fbo);
  {$ENDIF}
  glGenTextures(1,@tex.texname);
  glActiveTexture(GL_TEXTURE0+9); // don't damage units 0..8
  glBindTexture(GL_TEXTURE_2D,tex.texname);
  tex.SetLabel;
  glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
  tex.filter:=fltBilinear;
  GetGLFormat(PixFmt,format,subFormat,internalFormat);
  glTexImage2D(GL_TEXTURE_2D,0,internalFormat,width,height,0,format,subFormat,nil);
  {$IFDEF GLES11}
  glFramebufferTexture2DOES(GL_FRAMEBUFFER_OES,GL_COLOR_ATTACHMENT0_OES,GL_TEXTURE_2D,tex.texname,0);
  status:=glCheckFramebufferStatusOES(GL_FRAMEBUFFER_OES);
  if status<>GL_FRAMEBUFFER_COMPLETE_OES then
   raise EError.Create('FBO status: '+inttostr(status));
  {$ELSE}
  glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,zTex.texname,0);
  status:=glCheckFramebufferStatus(GL_FRAMEBUFFER);
  if status<>GL_FRAMEBUFFER_COMPLETE then
   raise EError.Create('FBO status: '+inttostr(status));
  {$ENDIF}

  {$ENDIF GLES}

  {$IFNDEF GLES}
  // Standard way: use FBO
  glGenFramebuffers(1,@tex.fbo);
  CheckForGLError('1');
  // Save current framebuffer
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,@prevFramebuffer);
  glBindFramebuffer(GL_FRAMEBUFFER,tex.fbo);
  CheckForGLError('2');
  glGenTextures(1,@tex.texname);
  glActiveTexture(GL_TEXTURE0+9); // don't damage units 0..8
  glBindTexture(GL_TEXTURE_2D,tex.texname);
  CheckForGLError('3');
  glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
  tex.filter:=fltBilinear;
  if HasFlag(flags,aiClampUV) then begin
   glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);
   glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
   SetFlag(tex.caps,tfClamped);
  end;
  if (tex.pixelFormat=ipfNone) and HasFlag(flags,aiDepthBuffer) then begin
   // No pixel format, but need depth buffer: allocate depth texture only
   glTexImage2D(GL_TEXTURE_2D,0,GL_DEPTH_COMPONENT,tex.width,tex.height,0,GL_DEPTH_COMPONENT,GL_FLOAT,nil);
   glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
   glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
   glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_COMPARE_MODE,GL_COMPARE_REF_TO_TEXTURE); // enable comparison mode
   glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_COMPARE_FUNC,GL_LESS); // enable comparison mode

   glFramebufferTexture2D(GL_FRAMEBUFFER,GL_DEPTH_ATTACHMENT,GL_TEXTURE_2D,tex.texname,0);
   glDrawBuffer(GL_NONE);
   glReadBuffer(GL_NONE);
  end else begin
   GetGLFormat(tex.pixelFormat,format,subFormat,internalFormat);
   glTexImage2D(GL_TEXTURE_2D,0,internalFormat,tex.width,tex.height,0,format,subFormat,nil);
   CheckForGLError('4');
   glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,tex.texname,0);

   if HasFlag(flags,aiDepthBuffer) then begin
    glGenRenderbuffers(1,@renderBuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, renderBuffer);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT, tex.width, tex.height);
    glFramebufferRenderBuffer(GL_FRAMEBUFFER,GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, renderBuffer);
    tex.rbo:=renderBuffer;
   end;
   glDrawBuffer(GL_COLOR_ATTACHMENT0);
  end;

  status:=glCheckFramebufferStatus(GL_FRAMEBUFFER);
  // Restore previous framebuffer binding
  glBindFramebuffer(GL_FRAMEBUFFER,prevFramebuffer);

  if status<>GL_FRAMEBUFFER_COMPLETE then
   raise EError.Create('FBO status: '+inttostr(status));

  {$ENDIF}
  SetFlag(tex.caps,tfRenderTarget+tfNoRead+tfNoWrite);
  tex.online:=true;
 end;
end;


function TGLResourceManager.AllocImage(width,height:integer; PixFmt:TImagePixelFormat; flags:cardinal;
  name:String8):TTexture;
var
 tex:TGlTexture;
 dataSize:integer;
begin
 ASSERT((width>0) AND (height>0),'Zero width or height: '+name);
 ASSERT((pixFmt<>ipfNone) or HasFlag(flags,aiDepthBuffer),'Invalid pixel format for '+name);
 if NoFlag(flags,aiSysMem) and ((width>maxTextureSize) or (height>maxTextureSize)) then
  raise EWarning.Create('AI: Texture too large');
 try
 EnterCriticalSection(cSect);
 try
 tex:=TGLTexture.Create;
 result:=tex;
 tex.width:=width;
 tex.height:=height;
 if HasFlag(flags,aiPow2) {$IFNDEF GLES} or
     not GL_ARB_texture_non_power_of_two {$ENDIF} then begin
  width:=GetPow2(width);
  height:=GetPow2(height);
 end;
 tex.realwidth:=width;
 tex.realHeight:=height;
 tex.name:=name;
 tex.PixelFormat:=PixFmt;
 tex.online:=false;
 if HasFlag(flags,aiPixelated) then
  tex.filter:=fltNearest
 else
  tex.filter:=fltTrilinear;

 if flags and aiRenderTarget>0 then begin
  AllocRenderTarget(tex,flags);
 end else begin
  // Not render target -> NO ANY GL* CALLS TO ALLOW MULTITHREADED ALLOCATION
  tex.pitch:=width*pixelSize[pixFmt] div 8;
  datasize:=tex.pitch*height;
  if pixFMT in [ipfDXT1,ipfDXT3,ipfDXT5] then begin
   tex.pitch:=tex.pitch div 4;
   datasize:=datasize div 16;
  end;
  SetLength(tex.realData[0],datasize);

  SetFlag(tex.caps,tfDirectAccess); // Can be locked
  if HasFlag(flags,aiClampUV) then
   SetFlag(tex.caps,tfClamped);
  // Mip-maps -> enable automatic generation
  if HasFlag(flags,aiAutoMipmap) then begin
   SetFlag(tex.caps,tfAutoMipMap);
   tex.mipmaps:=Log2i(max2(width,height));
  end;
 end;

 // Image can use the texture partialy
 tex.u1:=0; tex.u2:=tex.width/width;
 tex.v1:=0; tex.v2:=tex.height/height;
 tex.stepU:=0.5*(tex.u2-tex.u1)/tex.width;
 tex.stepV:=0.5*(tex.v2-tex.v1)/tex.height;
 finally LeaveCriticalSection(cSect);
 end;
 except
  on e:Exception do begin
   if tex<>nil then tex.Free;
   result:=nil;
   LogMessage('AllocImage error: '+ExceptionMsg(e));
   raise;
  end;
 end;
end;

function TGLResourceManager.AllocArray(width,height:integer;PixFmt:TImagePixelFormat;
                arraySize:integer;flags:cardinal;name:String8):TGLTextureArray;
var
 tex:TGlTextureArray;
 dataSize,z:integer;
begin
 ASSERT((width>0) AND (height>0),'Zero width or height: '+name);
 ASSERT((pixFmt<>ipfNone) or HasFlag(flags,aiDepthBuffer),'Invalid pixel format for '+name);
 if (flags and aiSysMem=0) and ((width>maxTextureSize) or (height>maxTextureSize)) then
  raise EWarning.Create('AI: Texture too large');
 try
 EnterCriticalSection(cSect);
 try
 tex:=TGLTextureArray.Create(arraySize);
 result:=tex;
 tex.width:=width;
 tex.height:=height;
 if (flags and aiPow2>0) {$IFNDEF GLES} or
     not GL_ARB_texture_non_power_of_two {$ENDIF} then begin
  width:=GetPow2(width);
  height:=GetPow2(height);
 end;
 tex.realwidth:=width;
 tex.realHeight:=height;
 tex.name:=name;
 tex.pixelFormat:=pixFmt;
 tex.online:=false;
 if HasFlag(flags,aiPixelated) then
  tex.filter:=fltNearest
 else
  tex.filter:=fltTrilinear;

 tex.pitch:=width*pixelSize[pixFmt] div 8;
 datasize:=tex.pitch*height;
 if pixFMT in [ipfDXT1,ipfDXT3,ipfDXT5] then begin
  tex.pitch:=tex.pitch div 4;
  datasize:=datasize div 16;
 end;
 for z:=0 to high(tex.layers) do begin
  tex.layers[z].width:=width;
  tex.layers[z].height:=height;
  tex.layers[z].pixelFormat:=tex.pixelFormat;
  SetLength(tex.layers[z].realData[0],datasize);
 end;

 SetFlag(tex.caps,tfDirectAccess); // Can be locked
 if HasFlag(flags,aiClampUV) then
  SetFlag(tex.caps,tfClamped);
  // Mip-maps
 if HasFlag(flags,aiAutoMipmap) then begin
  SetFlag(tex.caps,tfAutoMipMap);
  tex.mipmaps:=Log2i(max2(width,height));
 end;

 tex.u1:=0; tex.u2:=tex.width/width;
 tex.v1:=0; tex.v2:=tex.height/height;
 tex.stepU:=0.5*(tex.u2-tex.u1)/tex.width;
 tex.stepV:=0.5*(tex.v2-tex.v1)/tex.height;
 finally LeaveCriticalSection(cSect);
 end;
 except
  on e:Exception do begin
   if tex<>nil then tex.Free;
   result:=nil;
   LogMessage('AllocImage error: '+ExceptionMsg(e));
   raise;
  end;
 end;
end;


function TGLResourceManager.Clone(img:TTexture):TTexture;
var
 res,src:TGLTexture;
begin
 ASSERT(img is TGLTexture);
 src:=TGLTexture(img);

 res:=TGLTexture.Create;
 res.CloneFrom(img);
 res.texname:=src.texname;
 res.realWidth:=src.realWidth;
 res.realHeight:=src.realHeight;
 res.filter:=src.filter;
 res.online:=src.online;
 // Мда... И как тут сделать ссылку на данные!?
 result:=res;
end;

constructor TGLResourceManager.Create;
begin
 try
  resourceManagerGL:=self;
  _AddRef;

  glPixelStorei(GL_UNPACK_ALIGNMENT,1);
  mainThreadID:=GetCurrentThreadId;
  resourceManagerGL:=self;
  SetEventHandler('GLImages',EventHandler,emMixed);
  {$IFDEF GLES}
  glGetIntegerv(GL_MAX_TEXTURE_SIZE, @maxTextureSize);
  maxRBsize:=maxTextureSize;
  {$ELSE}
  glGetIntegerv(GL_MAX_TEXTURE_SIZE, @maxTextureSize);
  glGetIntegerv(GL_MAX_RENDERBUFFER_SIZE, @maxRBsize);
  {$ENDIF}
  maxRTsize:=min2(maxTextureSize,maxRBsize);
  LogMessage(Format('Maximal sizes: TEX: %d / RT: %d / RB: %d',[maxTextureSize,maxRTsize,maxRBsize]));
 except
  on e:Exception do begin
   ForceLogMessage('Error in GLTexMan constructor: '+ExceptionMsg(e));
   raise EFatalError.Create('GLTextMan: '+ExceptionMsg(e));
  end;
 end;
 CheckForGLError('ResMan.Create');
end;

destructor TGLResourceManager.Destroy;
begin
 resourceManagerGL:=nil;
 inherited;
end;

procedure TGLResourceManager.Dump(st:string);
begin

end;

procedure TGLResourceManager.FreeImage(var image: TTexture);
var
 tex:TGLTexture;
 level:integer;
begin
 if image=nil then exit;
 // Wrong thread?
 if GetCurrentThreadID<>mainThreadID then begin
  if not (image is TGLTexture) then raise EError.Create('Not a GLTexture! '+IntToHEx(cardinal(image),8));
  Signal('GLIMAGES\DeleteTexture',cardinal(image));
  image:=nil;
  exit;
 end;
 EnterCriticalSection(cSect);
 try

 dec(image.refCounter);
 if image.refCounter>=0 then begin
  image:=nil;
  exit; // prevent object deletion
 end;

 if image.parent<>nil then FreeImage(image.parent);

 if image is TGLTexture then begin
  tex:=image as TGLTexture;
  if tex.fbo<>0 then begin // free framebuffer
   {$IFDEF GLES11}
   glDeleteFramebuffersOES(1,@tex.fbo);
   {$ENDIF}
   {$IFDEF GLES20}
   glDeleteFramebuffers(1,@tex.fbo)
   {$ENDIF}
   {$IFNDEF GLES}
   if GL_ARB_framebuffer_object then
    glDeleteFramebuffers(1,@tex.fbo)
   else
   if GL_EXT_framebuffer_object then
    glDeleteFramebuffersExt(1,@tex.fbo)
   else
    raise EError.Create('TexMan FI: framebuffers not supported!');
   {$ENDIF}
  end;
  if tex.rbo<>0 then glDeleteRenderbuffers(1,@tex.rbo);
  tex.rbo:=0;
  if tex.texname<>0 then glDeleteTextures(1,@tex.texname);
  tex.texname:=0;
  tex.Free;
  image:=nil;
 end else
  raise EWarning.Create('FI: not a GL texture');
 finally
  LeaveCriticalSection(cSect);
 end;
end;

procedure TGLResourceManager.FreeMetaTexSpace(n: integer);
begin

end;

procedure TGLResourceManager.FreeVidMem;
begin

end;

function TGLResourceManager.GetStatus(line: byte): string;
begin

end;

procedure TGLResourceManager.SetTexFilter(img:TTexture;filter:TTexFilter);
begin
 TGLTexture(img).filter:=filter;
 TGLTexture(img).UpdateFilter;
end;

procedure TGLResourceManager.MakeOnline(img: TTexture;stage:integer=0);
var
 tex:TGLTexture;
begin
 if img=nil then begin
  curTextures[stage]:=nil;
  exit;
 end;
 ASSERT(img is TGLTexture);
 tex:=TGLTexture(img);
 if (curTextures[stage]=tex) and tex.online then exit;
 glActiveTexture(GL_TEXTURE0+stage);
 if curTextures[stage]<>tex then tex.Bind;
 curTextures[stage]:=tex;
 if not tex.online then tex.UploadData;
end;

function TGLResourceManager.QueryParams(width, height: integer;
  format: TImagePixelFormat; usage: integer): boolean;
var
 res:integer;
 glFormat,subFormat,InternalFormat:cardinal;
begin
 result:=true;
 if not (format in [ipfARGB,ipfRGB,ipf1555,ipf4444,ipf565]) then begin
  result:=false;
  exit;
 end;
 if (width>MAX_TEX_SIZE) or (height>MAX_TEX_SIZE) then begin
  result:=false;
  exit;
 end;
 {$IFNDEF GLES}
 GetGLFormat(format,glFormat,subFormat,internalFormat);
 glTexImage2D(GL_PROXY_TEXTURE_2D,0,internalFormat,width,height,0,glFormat,subFormat,nil);
 glGetTexLevelParameteriv(GL_PROXY_TEXTURE_2D,0,GL_TEXTURE_INTERNAL_FORMAT,@res);
 CheckForGLError('18');
 if res=0 then result:=false;
 {$ENDIF}
end;

procedure TGLResourceManager.ResizeImage(var img: TTexture; newWidth,
  newHeight: integer);
var
 glFormat,subFormat,internalFormat:cardinal;
 old:TTexture;
begin
 if img.HasFlag(tfRenderTarget) then
  with img as TGLTexture do begin
   glBindTexture(GL_TEXTURE_2D, texname);
   GetGLFormat(img.PixelFormat,glFormat,subFormat,internalFormat);
   width:=newWidth;
   height:=newHeight;
   glTexImage2D(GL_TEXTURE_2D,0,internalFormat,width,height,0,glFormat,subFormat,nil);
   CheckForGLError('19');
   if rbo<>0 then begin
    glBindRenderbuffer(GL_RENDERBUFFER, rbo);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT, width, height);
   end;
   exit;
  end;
 // Delete and allocate again
 old:=img;
 img:=AllocImage(newWidth,newHeight,img.PixelFormat,img.caps,img.name);
 FreeImage(old);
end;

begin
 InitCritSect(cSect,'GLTexMan',160);
end.
