const fs=require('fs'),{PNG}=require('pngjs'),pm=require('pixelmatch');const a=process.argv[2],b=process.argv[3];let bad=0;
for(const f of fs.readdirSync(a)){if(!f.endsWith('.png'))continue;const A=PNG.sync.read(fs.readFileSync(a+'/'+f)),B=PNG.sync.read(fs.readFileSync(b+'/'+f));
 if(A.width!==B.width||A.height!==B.height){console.log(f,'SIZE DIFF',A.width+'x'+A.height,'vs',B.width+'x'+B.height);bad++;continue;}
 const n=pm(A.data,B.data,null,A.width,A.height,{threshold:0.05});console.log(f,n===0?'identical':n+' px differ ('+(100*n/(A.width*A.height)).toFixed(3)+'%)');if(n)bad++;}
console.log(bad?bad+' files differ':'ALL IDENTICAL');
