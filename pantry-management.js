(() => {
'use strict';
window.PANTRY_MANAGEMENT_ACTIVE=true;
const cfg=window.SNACK_PASS_CONFIG||{};
if(!window.supabase||!cfg.supabaseUrl||!cfg.supabaseAnonKey)return;
const db=window.supabase.createClient(cfg.supabaseUrl,cfg.supabaseAnonKey);
const $=id=>document.getElementById(id);
const catalog=[['Pringles',27,13.98,1],['Nerd Clusters',24,29.53,2],['Rice Krispies',40,10.99,1],['Mothers Circus',30,15.64,1],['Miss Vickies',28,18.49,2],['Goldfish',30,15.99,1],['Chip Pack',40,22.43,2],['Gushers',42,22.95,2],['Welches',80,16,1],['Veggie Straw',24,32,2],['Oreo',60,18.65,1],['Skinny Pop',30,18.20,1],['Yoggies',30,23.99,1],['Skittles and Starbursts',30,27.99,2],['Blakes Bars',24,29.99,2]];
const aliases={nerdsclusters:'nerdclusters',nerdsgummyclusters:'nerdclusters',ricekrispiestreats:'ricekrispies',motherscircuscookies:'motherscircus',missvickieschips:'missvickies',welchs:'welches',welchsfruitsnacks:'welches',veggiestraws:'veggiestraw',oreocookies:'oreo',blakesseedbars:'blakesbars'};
const norm=s=>String(s||'').toLowerCase().replace(/[^a-z0-9]/g,'');
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;','\'':'&#39;'}[c]));
const money=n=>'$'+Number(n||0).toFixed(3);
let rows=[],snackLoad=0;
function findCatalog(name){return window.PANTRY_PRICE_BOOK?.find(name)||catalog.find(x=>norm(x[0])===norm(name));}
async function readSnacks(){
 const {data,error}=await db.from('snacks').select('id,barcode,name,price,stock,pack_size,pack_cost,fbla_price,active').order('name').limit(1000);
 if(error)throw error;rows=data||[];return rows;
}
function setError(e){alert((e&&e.message)||String(e));}
async function draw(){
 await readSnacks();
 const query=$('snack-search').value.trim().toLowerCase();
 const found=rows.filter(x=>(x.name+' '+x.barcode).toLowerCase().includes(query));
 $('snack-rows').innerHTML=found.map(sn=>{
  const c=findCatalog(sn.name);
  const qty=sn.pack_size??c?.[1]??null;
  const cost=sn.pack_cost??c?.[2]??null;
  const unit=qty&&cost!==null?money(cost/qty):'Needs cost';
  return '<tr><td><strong>'+esc(sn.name)+'</strong></td><td class="mono">'+esc(sn.barcode)+'</td><td>'+Number(sn.price).toFixed(2)+' USD ('+sn.price+' pt)</td><td>'+unit+'</td><td>'+(qty??'—')+'</td><td>'+(sn.stock??'Untracked')+'</td><td>'+(sn.active?'Active':'Inactive')+'</td><td class="actions">'+
  (window.PANTRY_IS_ADMIN ? '<button type="button" class="btn smallbtn" data-manage="edit" data-code="'+esc(sn.barcode)+'">Edit</button> ' : '')+
  (window.PANTRY_IS_ADMIN ? '<button type="button" class="btn smallbtn" data-manage="stock" data-code="'+esc(sn.barcode)+'">Set stock</button> ' : '')+
  (window.PANTRY_IS_ADMIN ? '<button type="button" class="btn smallbtn danger" data-manage="remove" data-code="'+esc(sn.barcode)+'">Remove</button>' : 'View only')+'</td></tr>';
 }).join('')||'<tr><td colspan="8" class="empty">No snacks match.</td></tr>';
}
const preset=$('snack-preset');
catalog.forEach((c,i)=>preset.add(new Option(c[0]+' | '+money(c[2]/c[1])+' per unit | $'+c[3]+' sell',String(i))));
preset.addEventListener('change',()=>{
 if(preset.value==='')return;
 const c=catalog[Number(preset.value)];
 $('snack-name').value=c[0];$('snack-price').value=c[3];$('snack-pack-size').value=c[1];$('snack-pack-cost').value=c[2].toFixed(2);
 const found=rows.find(s=>norm(s.name)===norm(c[0]));
 $('snack-barcode').value=found?.barcode||'';
 $('snack-stock').value=found?.stock??'';
 $('snack-fbla-price').value=found?.fbla_price??'';
});
$('snack-form').addEventListener('submit',async e=>{
 e.preventDefault();e.stopImmediatePropagation();
 const barcode=$('snack-barcode').value.trim(),name=$('snack-name').value.trim(),price=Number($('snack-price').value);
 const rawStock=$('snack-stock').value.trim(),rawQty=$('snack-pack-size').value.trim(),rawCost=$('snack-pack-cost').value.trim(),rawFbla=$('snack-fbla-price').value;
 let stock=rawStock===''?null:Number(rawStock),qty=rawQty===''?null:Number(rawQty),cost=rawCost===''?null:Number(rawCost),fbla=rawFbla===''?null:Number(rawFbla);
 const c=findCatalog(name);
 if(c){qty=qty??c[1];cost=cost??c[2];}
 if(!barcode||!name||![1,2].includes(price)||(stock!==null&&(!Number.isInteger(stock)||stock<0))||(qty===null)!==(cost===null)||(qty!==null&&(!Number.isInteger(qty)||qty<1))||(cost!==null&&(!Number.isFinite(cost)||cost<0))||(fbla!==null&&(![1,2].includes(fbla)||fbla>price))){alert('Check barcode, price, pack cost, pack quantity and stock.');return;}
 try{const {error}=await db.rpc('save_snack_v2',{p_barcode:barcode,p_name:name,p_price:price,p_stock:stock,p_pack_cost:cost,p_pack_size:qty,p_fbla_price:fbla});if(error)throw error;
 $('snack-form').reset();await draw();alert('Snack saved.');window.dispatchEvent(new Event('pantry-updated'));
 }catch(err){setError(err);}
},true);
$('snack-rows').addEventListener('click',async e=>{
 const btn=e.target.closest('[data-manage]');if(!btn)return;
 e.preventDefault();e.stopImmediatePropagation();
 const sn=rows.find(s=>s.barcode===btn.dataset.code);if(!sn)return;
 if(btn.dataset.manage==='edit'){
  const c=findCatalog(sn.name);
  $('snack-barcode').value=sn.barcode;$('snack-name').value=sn.name;$('snack-price').value=sn.price;
  $('snack-stock').value=sn.stock??'';$('snack-pack-cost').value=sn.pack_cost??c?.[2]??'';
  $('snack-pack-size').value=sn.pack_size??c?.[1]??'';$('snack-fbla-price').value=sn.fbla_price??'';
  $('snack-barcode').focus();window.scrollTo({top:0,behavior:'smooth'});return;
 }
 if(btn.dataset.manage==='stock'){
  const raw=prompt('Actual stock on hand for '+sn.name+':',sn.stock??'');
  if(raw===null)return;const count=Number(raw);
  if(!raw.trim()||!Number.isInteger(count)||count<0){alert('Enter a nonnegative whole number.');return;}
  btn.disabled=true;
  try{const {error}=await db.rpc('set_snack_stock_count',{p_barcode:sn.barcode,p_stock:count});if(error)throw error;await draw();window.dispatchEvent(new Event('pantry-updated'));}
  catch(err){setError(err);}finally{btn.disabled=false;}return;
 }
 if(btn.dataset.manage==='remove'){
  if(!window.PANTRY_IS_ADMIN)return alert('Only the administrator may remove snacks.');
  if(!confirm('Permanently remove '+sn.name+'? Prior sales will remain in the audit trail.'))return;
  const adminCode=await window.PANTRY_SCAN_ADMIN_BARCODE();if(!adminCode)return;
  btn.disabled=true;
  try{const {error}=await db.rpc('admin_remove_snack',{p_snack_barcode:sn.barcode,p_admin_barcode:adminCode});if(error)throw error;await draw();window.dispatchEvent(new Event('pantry-updated'));}
  catch(err){setError(err);}finally{btn.disabled=false;}
 }
},true);
$('snack-search').addEventListener('input',()=>draw().catch(()=>{}));
window.addEventListener('pantry-role-ready',()=>{if(!$('tab-snacks').classList.contains('hidden'))draw().catch(()=>{});});
document.querySelector('[data-tab="snacks"]').addEventListener('click',()=>draw().catch(setError));
window.addEventListener('pantry-updated',()=>{if(!$('tab-snacks').classList.contains('hidden'))draw().catch(()=>{});});
window.PANTRY_CATALOG=catalog;
window.PANTRY_MATCH=findCatalog;
})();