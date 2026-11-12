// Photoshop 图鉴脚本：只操作传入的工作文档，以图层 ID 绑定角色，保留组投影和人工布局。
import Foundation

nonisolated enum CardPhotoshopScript {
    static let source = #"""
function cardRun(q) {
 var units=app.preferences.rulerUnits, dialogs=app.displayDialogs;
 app.preferences.rulerUnits=Units.PIXELS;app.displayDialogs=DialogModes.NO;
 function sid(s){return stringIDToTypeID(s);}
 function enc(o){if(o===null)return 'null';if(typeof o=='string')return '"'+o.replace(/\\/g,'\\\\').replace(/"/g,'\\"').replace(/\r/g,'\\r').replace(/\n/g,'\\n').replace(/\t/g,'\\t')+'"';if(typeof o!='object')return String(o);var a=[],k;if(o instanceof Array){for(k=0;k<o.length;k++)a.push(enc(o[k]));return '['+a.join(',')+']';}for(k in o)if(o.hasOwnProperty(k))a.push(enc(k)+':'+enc(o[k]));return '{'+a.join(',')+'}';}
 function empty(){return {roles:{},chineseName:'',latinName:'',collectionText:'',sex:'unknown',width:0,height:0,collision:false,frontSize:[],backSize:[]};}
 var doc=null, path=new File(q.working).fsName;
 function bounds(l){var b=l.boundsNoEffects||l.bounds;return [b[0].as('px'),b[1].as('px'),b[2].as('px'),b[3].as('px')];}
 function byID(p,id){for(var i=0;i<p.layers.length;i++){var l=p.layers[i];if(l.id==id)return l;if(l.typename=='LayerSet'){var found=byID(l,id);if(found)return found;}}return null;}
 function byName(p,name){for(var i=0;i<p.layers.length;i++){var l=p.layers[i];if(l.name==name)return l;if(l.typename=='LayerSet'){var found=byName(l,name);if(found)return found;}}return null;}
 try {
  for(var i=0;i<app.documents.length;i++){try{if(app.documents[i].fullName.fsName==path)doc=app.documents[i];}catch(e){}}
  if(q.operation=='close'){if(doc){if(!doc.saved)throw Error('工作 PSD 尚未保存，请先在 Photoshop 保存');doc.close(SaveOptions.DONOTSAVECHANGES);}return enc(empty());}
  if(!doc)doc=app.open(new File(path));
  app.activeDocument=doc;
  if(q.operation=='activate'){app.bringToFront();return enc(empty());}
  if(!doc.saved)throw Error('工作 PSD 尚未保存，请先在 Photoshop 保存，再返回刷新');
  if(q.operation=='check')return enc(empty());
  if(doc.width.as('px')!=4000||doc.height.as('px')!=2250||doc.mode!=DocumentMode.RGB)throw Error('模板需要为 4000 × 2250 RGB 图像');
  var roles=q.roles, female,male,latin,collection,credit,chinese,butterfly,text,shape,bg,front,back;
  if(!roles){
   text=byName(doc,'TEXT');butterfly=byName(doc,'Butterfly');shape=byName(doc,'Shape');bg=byName(doc,'85BG');
   if(!text||!butterfly||!shape||!bg||text.typename!='LayerSet'||butterfly.typename!='LayerSet'||text.layers.length!=6)throw Error('模板图层结构不符，未写入文字');
   var keys=['female','male','latin','collection','credit','chinese'];roles={text:text.id,butterfly:butterfly.id,shape:shape.id,bg:bg.id};
   for(i=0;i<6;i++){if(text.layers[i].kind!=LayerKind.TEXT)throw Error('TEXT 需要六个文字图层');roles[keys[i]]=text.layers[i].id;}
   if(text.layers[0].textItem.contents!='♀'||text.layers[1].textItem.contents!='♂'||text.layers[4].textItem.contents!='Image Hans Collection.')throw Error('模板文字角色顺序不符');
   function place(source,name){var src=app.open(new File(source)), layer;try{layer=src.activeLayer.duplicate(doc,ElementPlacement.PLACEATBEGINNING);}finally{src.close(SaveOptions.DONOTSAVECHANGES);}app.activeDocument=doc;doc.activeLayer=layer;executeAction(sid('newPlacedLayer'),undefined,DialogModes.NO);layer=doc.activeLayer;layer.name=name;layer.move(butterfly,ElementPlacement.INSIDE);return layer;}
   // 仅初始化时替换示例；已有角色 ID 时绝不重新置入。
   for(i=butterfly.layers.length-1;i>=0;i--)butterfly.layers[i].remove();
   front=place(q.front,'D 正面');back=place(q.back,'V 反面');roles.front=front.id;roles.back=back.id;
  }
  function role(key,type){var layer=byID(doc,roles[key]);if(!layer||(type&&layer.typename!=type))throw Error('图鉴角色图层丢失或类型改变：'+key);return layer;}
  text=role('text','LayerSet');butterfly=role('butterfly','LayerSet');shape=role('shape','LayerSet');bg=role('bg');front=role('front','ArtLayer');back=role('back','ArtLayer');
  female=role('female');male=role('male');latin=role('latin');collection=role('collection');credit=role('credit');chinese=role('chinese');
  var texts=[female,male,latin,collection,credit,chinese];
  for(i=0;i<texts.length;i++){if(texts[i].kind!=LayerKind.TEXT||texts[i].parent.id!=text.id)throw Error('文字图层类型或归属改变');try{app.fonts.getByName(texts[i].textItem.font);}catch(e){throw Error('模板字体缺失：'+texts[i].textItem.font);}}
  if(front.parent.id!=butterfly.id||back.parent.id!=butterfly.id)throw Error('图片图层已移出 Butterfly 组');
  if(credit.textItem.contents!='Image Hans Collection.')throw Error('固定署名已改变，请恢复 Image Hans Collection.');
  if(q.operation=='export'){
   var prefs=null;try{var pr=new ActionReference();pr.putProperty(sid('property'),sid('exportAssetsPrefs'));pr.putEnumerated(sid('application'),sid('ordinal'),sid('targetEnum'));prefs=executeActionGet(pr).getObjectValue(sid('exportAssetsPrefs'));}catch(e){}
   var srgb=true, metadata=0;
   if(prefs){try{srgb=prefs.getBoolean(sid('exportConvertToSRGB'));}catch(e){}try{metadata=prefs.getInteger(sid('exportMetaData'));}catch(e){}}
   var d=new ActionDescriptor(),r=new ActionReference();r.putEnumerated(sid('layer'),sid('ordinal'),sid('targetEnum'));d.putReference(sid('null'),r);d.putString(sid('fileType'),'png');d.putInteger(sid('quality'),32);d.putInteger(sid('metadata'),metadata);d.putBoolean(sid('sRGB'),srgb);d.putBoolean(sid('openWindow'),false);d.putBoolean(sid('promptForSaveLocation'),false);d.putString(sid('destFolder'),q.destination);executeAction(sid('exportDocumentAsFileTypePressed'),d,DialogModes.NO);return enc(empty());
  }
  if(q.operation=='prepare'){
   function setText(layer,value){layer.allLocked=false;layer.textItem.contents=value||' ';layer.visible=!!value;if(value){var b=bounds(layer);layer.translate(2000-(b[0]+b[2])/2,0);}}
   setText(latin,q.fields.latinName);setText(chinese,q.fields.chineseName);setText(collection,q.fields.collectionText);
   female.visible=q.fields.sex=='female';male.visible=q.fields.sex=='male';
  }
  shape.visible=false;bg.visible=true;text.visible=true;butterfly.visible=true;front.visible=true;back.visible=true;
  if(text.parent.id!=butterfly.parent.id)throw Error('TEXT 和 Butterfly 必须位于同一父组');
  text.move(butterfly,ElementPlacement.PLACEBEFORE);
  if(text.parent.typename=='LayerSet')text.parent.visible=true;
  var textBoxes=[];
  for(i=0;i<texts.length;i++)if(texts[i].visible){var b=bounds(texts[i]);if(b[0]<0||b[1]<0||b[2]>4000||b[3]>2250)throw Error('文字超出画布，请缩短内容或在 Photoshop 调整');textBoxes.push([b[0]-12,b[1]-12,b[2]+12,b[3]+12]);}
  function collision(layer){
   for(var j=0;j<textBoxes.length;j++){
    doc.activeLayer=layer;var sd=new ActionDescriptor(),to=new ActionReference(),from=new ActionReference();to.putProperty(charIDToTypeID('Chnl'),charIDToTypeID('fsel'));sd.putReference(charIDToTypeID('null'),to);from.putEnumerated(charIDToTypeID('Chnl'),charIDToTypeID('Chnl'),charIDToTypeID('Trsp'));sd.putReference(charIDToTypeID('T   '),from);executeAction(charIDToTypeID('setd'),sd,DialogModes.NO);
    var t=textBoxes[j];doc.selection.select([[t[0],t[1]],[t[2],t[1]],[t[2],t[3]],[t[0],t[3]]],SelectionType.INTERSECT,0,false);
    var hit=false;try{var sb=doc.selection.bounds;hit=sb[2].as('px')>sb[0].as('px')&&sb[3].as('px')>sb[1].as('px');}catch(e){}doc.selection.deselect();if(hit)return true;
   }return false;
  }
  var images=[front,back];
  if(q.operation=='layout'){
   function fit(layer,frame,factor){var b=bounds(layer),w=b[2]-b[0],h=b[3]-b[1];if(w<=0||h<=0)throw Error('PNG 没有可见主体');var scale=frame[2]*factor/w*100;layer.resize(scale,scale,AnchorPosition.MIDDLECENTER);b=bounds(layer);layer.translate(frame[0]+frame[2]/2-(b[0]+b[2])/2,frame[1]+frame[3]/2-(b[1]+b[3])/2);}
   for(i=0;i<2;i++)fit(images[i],q.frames[i],1);
   for(var n=0;n<180&&(collision(front)||collision(back));n++){for(i=0;i<2;i++)fit(images[i],q.frames[i],Math.pow(0.98,n+1));}
  }
  var collided=collision(front)||collision(back), f=bounds(front),v=bounds(back);
  if(f[2]<=f[0]||f[3]<=f[1]||v[2]<=v[0]||v[3]<=v[1])throw Error('PNG 没有可见主体');
  if(f[0]<0||f[1]<0||f[2]>4000||f[3]>2250||v[0]<0||v[1]<0||v[2]>4000||v[3]>2250)collided=true;
  doc.save();
  return enc({roles:roles,chineseName:chinese.visible?chinese.textItem.contents:'',latinName:latin.visible?latin.textItem.contents:'',collectionText:collection.visible?collection.textItem.contents:'',sex:female.visible?'female':male.visible?'male':'unknown',width:4000,height:2250,collision:collided,frontSize:[f[2]-f[0],f[3]-f[1]],backSize:[v[2]-v[0],v[3]-v[1]]});
 }finally{app.preferences.rulerUnits=units;app.displayDialogs=dialogs;}
}
"""#
}
