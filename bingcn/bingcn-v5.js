/* Bing CN Multi-Source Auto Search for Loon v5.0.0 */
const CFG={total:22,timeout:30000,minDelay:20000,maxDelay:40000,maxFailures:3,cookieKey:"BingCN_V4_Cookie",dateKey:"BingCN_V5_Date",countKey:"BingCN_V5_Count",queueDateKey:"BingCN_V5_QueueDate",queueKey:"BingCN_V5_Queue"};
const UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 Edg/126.0.0.0";
const SOURCES=["BaiduHot","TouTiaoHot","WeiBoHot","DouYinHot","Weather"];
const BUILTIN=["人工智能最新进展","新能源汽车行业动态","中国航天最新消息","夏季健康饮食指南","热门城市旅游攻略","中国传统文化知识","世界著名建筑介绍","手机数码新品资讯","电影电视剧最新消息","体育赛事今日热点","自然科学趣味知识","家庭园艺实用技巧","摄影构图入门技巧","历史人物故事介绍","古典音乐入门推荐","海洋生物科普知识","环境保护最新进展","博物馆热门展览","天文观测入门知识","家常美食制作方法","诗词鉴赏基础方法","经济学基础知识","编程入门学习路线","心理健康生活常识","城市公共交通发展","中国地理自然风光","语言学习实用方法","运动健身科学方法","阅读书籍热门推荐","今日国内新闻热点"];
const APPKEY=(typeof $argument!=="undefined"&&$argument&&$argument.appkey?String($argument.appkey):"").trim();
main().catch(e=>finish("❌ 脚本异常："+(e.message||e)));
async function main(){
 const cookie=$persistentStore.read(CFG.cookieKey)||"";if(!cookie)return finish("⚠️ 没有Cookie，请先登录微软账号并搜索一次");
 const day=dateString();let count=Number($persistentStore.read(CFG.countKey)||0);
 if(($persistentStore.read(CFG.dateKey)||"")!==day||!Number.isFinite(count)||count<0||count>CFG.total){count=0;$persistentStore.write(day,CFG.dateKey);$persistentStore.write("0",CFG.countKey);}
 if(count>=CFG.total)return finish(`✅ ${day} 已完成 ${CFG.total}/${CFG.total}，不重复执行`);
 let queue=loadQueue(day);if(queue.length<CFG.total){queue=await buildUniqueQueue();$persistentStore.write(day,CFG.queueDateKey);$persistentStore.write(JSON.stringify(queue),CFG.queueKey);}
 console.log(`[BingCN V6] 唯一搜索词队列：${queue.length}个`);queue.forEach((w,i)=>console.log(`[BingCN V6] 词 ${i+1}: ${w}`));
 let failures=0;
 while(count<CFG.total&&failures<CFG.maxFailures){const word=queue[count];const url=searchUrl(word);console.log(`[BingCN V6] 🔎 ${count+1}/${CFG.total}：${word}`);const r=await get(url,{"Cookie":cookie,"User-Agent":UA,"Accept":"text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8","Accept-Language":"zh-CN,zh;q=0.9,en;q=0.7"});if(r.ok){count++;failures=0;$persistentStore.write(String(count),CFG.countKey);console.log(`[BingCN V6] ✅ ${count}/${CFG.total} HTTP ${r.status}，${r.length}字节`);}else{failures++;console.log(`[BingCN V6] ❌ ${failures}/${CFG.maxFailures}：${r.error} HTTP ${r.status}`);}if(count<CFG.total&&failures<CFG.maxFailures){const wait=rand(CFG.minDelay,CFG.maxDelay);console.log(`[BingCN V6] ⏳ 等待 ${(wait/1000).toFixed(1)} 秒后进行下一次搜索`);await sleep(wait);}}
 finish(`${day}\n后台搜索进度：${count}/${CFG.total}\n22个关键词已严格去重\n域名：cn.bing.com${count<CFG.total?`\n连续失败：${failures}`:"\n✅ 搜索请求已完成"}\n积分以Rewards实际入账为准`);
}
function loadQueue(day){if(($persistentStore.read(CFG.queueDateKey)||"")!==day)return[];try{const q=JSON.parse($persistentStore.read(CFG.queueKey)||"[]");return Array.isArray(q)&&uniqueWords(q).length===q.length?q:[];}catch(e){return[];}}
async function buildUniqueQueue(){
 const buckets=[];
 for(const src of SOURCES){const sep=src==="Weather"?"?":"?format=json&";const key=APPKEY?`appkey=${encodeURIComponent(APPKEY)}`:"";const url=`https://api.gmya.net/Api/${src}${sep}${key}`;console.log(`[BingCN V6] 获取 ${src}`);const r=await get(url,{"User-Agent":UA,"Accept":"application/json"});let words=[];if(r.ok){try{const j=JSON.parse(r.body);words=src==="Weather"?weatherWords(j):((j.data||[]).map(x=>x&&x.title).filter(Boolean));}catch(e){console.log(`[BingCN V6] ${src}解析失败：${e}`);}}else console.log(`[BingCN V6] ${src}请求失败：${r.error} HTTP ${r.status}`);words=uniqueWords(words);console.log(`[BingCN V6] ${src} 提取唯一词 ${words.length}个`);buckets.push({src,words:shuffle(words),pos:0});
 }
 const out=[],seen=new Set();let progressed=true;
 while(out.length<CFG.total&&progressed){progressed=false;for(const b of buckets){while(b.pos<b.words.length){const w=clean(b.words[b.pos++]),k=normalize(w);if(!w||seen.has(k))continue;seen.add(k);out.push(w);progressed=true;break;}if(out.length>=CFG.total)break;}}
 for(const w of shuffle(BUILTIN)){const x=clean(w),k=normalize(x);if(x&&!seen.has(k)){seen.add(k);out.push(x);}if(out.length>=CFG.total)break;}
 return out.slice(0,CFG.total);
}
function weatherWords(j){const d=j&&j.data||{},loc=d.location||{},city=loc.city||"北京",a=Array.isArray(d.daily)?d.daily:[];const out=[];for(const x of a){out.push(`${city}${x.date||"今日"}天气 ${x.text_day||""} ${x.low||""}到${x.high||""}度`);out.push(`${city}${x.date||"今日"}风力湿度 ${x.wind_direction||""}风${x.wind_scale||""}级 湿度${x.humidity||""}%`);}return out;}
function uniqueWords(a){const out=[],seen=new Set();for(const v of a){const w=clean(v),k=normalize(w);if(w&&k&&!seen.has(k)){seen.add(k);out.push(w);}}return out;}
function clean(v){return String(v||"").replace(/\s+/g," ").trim().slice(0,80);}
function normalize(v){return clean(v).toLowerCase().replace(/[\s\p{P}\p{S}]+/gu,"");}
function searchUrl(w){const q=encodeURIComponent(w);return `https://cn.bing.com/search?q=${q}&form=${randomText(4)}&cvid=${randomText(32)}&sp=-1&lq=0&pq=${q}&sc=8-0&qs=n&sk=`;}
function get(url,headers){return new Promise(resolve=>$httpClient.get({url,headers,timeout:CFG.timeout},(error,response,data)=>{const status=Number(response&&(response.status||response.statusCode)||0),body=typeof data==="string"?data:"";if(error)return resolve({ok:false,error:String(error),status,body,length:body.length});resolve({ok:status>=200&&status<400,error:status?`HTTP ${status}`:"无响应",status,body,length:body.length});}));}
function dateString(){const d=new Date();return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,"0")}-${String(d.getDate()).padStart(2,"0")}`;}function rand(a,b){return Math.floor(Math.random()*(b-a+1))+a;}function randomText(n){const c="ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";let s="";while(s.length<n)s+=c[rand(0,c.length-1)];return s;}function shuffle(a){a=a.slice();for(let i=a.length-1;i>0;i--){const j=rand(0,i);[a[i],a[j]]=[a[j],a[i]];}return a;}function sleep(ms){return new Promise(r=>setTimeout(r,ms));}function finish(s){console.log("[BingCN V6] "+s.replace(/\n/g," | "));$notification.post("Bing CN 自动搜索 V5","执行结果",s,{url:"https://rewards.bing.com/"});$done();}