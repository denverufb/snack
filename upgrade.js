(function upgrade(){
'use strict';
const cfg=window.SNACK_PASS_CONFIG||{};
if(!window.supabase||!cfg.supabaseUrl||!cfg.supabaseAnonKey)return;
const db=window.supabase.createClient(cfg.supabaseUrl,cfg.supabaseAnonKey);
const $=x=>document.getElementById(x),usd=x=>'$'+Number(x||0).toFixed(2);
const esc=x=>String(x??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let ready=false,loaded=false,fbla=false,scanning=false,items=[];
async function rpc(fn,p){const {data,error}=await db.rpc(fn,p||{});if(error)throw error;return data;}
function error(e){alert(e.message||String(e));}
async function inventory(){const {data,error:e}=await db.from('snacks').select('barcode,name,stock,pack_cost,pack_size,price,fbla_price').limit(2000);if(e)throw e;items=data||[];}
function refresh(){ $('refresh-activity').click(); inventory().catch(()=>{});report().catch(()=>{}); }
async function report(){
 if(!ready)return;
 try{
  const f=await rpc('get_snack_finances');
  const vals={'f-revenue':usd(f.sales_revenue),'f-profit':usd(f.gross_profit),'f-cogs':usd(f.cost_of_goods),'f-stockcost':usd(f.inventory_cost),'f-stockretail':usd(f.inventory_retail),'f-reloads':usd(f.reload_cash),'f-units':String(f.units_sold),'f-margin':Number(f.sales_revenue)?(100*Number(f.gross_profit)/Number(f.sales_revenue)).toFixed(1)+'%':'0%'};
  for(const [id,val] of Object.entries(vals))$(id).textContent=val;
  let prods=f.products||[];
  $('f-most').textContent=prods.filter(x=>x.sold>0).slice(0,5).map(x=>x.name+' ('+x.sold+')').join(', ')||'No sales yet';
  $('f-least').textContent=[...prods].sort((a,b)=>a.sold-b.sold).slice(0,5).map(x=>x.name+' ('+x.sold+')').join(', ')||'No products yet';
  $('f-rows').innerHTML=prods.map(x=>'<tr><td>'+esc(x.name)+'</td><td>'+x.sold+'</td><td>'+usd(x.revenue)+'</td><td>'+usd(x.gross_profit)+'</td><td>'+(x.stock??'Untracked')+'</td><td>'+(x.pack_size?usd(x.pack_cost/x.pack_size):'Unknown')+'</td></tr>').join('')||'<tr><td colspan="6">No snacks saved.</td></tr>';
  $('f-warning').textContent=f.unknown_cost_sales+' sales without known costs; '+f.estimated_legacy_sales+' historical sales use estimated costs; '+f.unvalued_products+' snacks have unknown inventory value.';
 }catch(e){$('f-warning').textContent=e.message;}
}
async function check(){
 try{await rpc('get_snack_finances');ready=true;$('f-setup').textContent='Financial upgrade connected.';await inventory();await report();}
 catch(e){ready=false;$('f-setup').textContent='Run upgrade_finance.sql in Supabase, then Refresh. '+e.message;}
}
const current=()=>($('student-box').querySelector('.mono')?.textContent||'').trim();
async function custom(){
 if(!ready)return alert('Run SQL upgrade first.');
 const code=current();if(!code)return alert('Select or scan a student first.');
 const input=prompt('Custom reload in whole dollars (1–500):');if(input===null)return;
 const n=Number(input);if(!Number.isInteger(n)||n<1||n>500)return alert('Use a whole number between 1 and 500.');
 if(!confirm('Confirm you collected $'+n+' from the student?'))return;
 try{const d=await rpc('reload_points_custom',{p_student_barcode:code,p_points:n,p_note:'Staff-confirmed $'+n+' reload',p_request_id:crypto.randomUUID()});$('checkout-status').textContent='Reload successful. New balance: '+d.balance+' points.';refresh();}
 catch(e){error(e);}
}
async function scan(e){
 if(e.key!=='Enter'||!fbla||!ready)return;
 const input=$('scan'),code=input.value.trim(),sn=items.find(x=>x.barcode===code);
 if(!sn)return;
 e.preventDefault();e.stopImmediatePropagation();input.value='';
 if(scanning)return;
 const st=current();if(!st)return $('checkout-status').textContent='Scan a student ID first.';
 if(sn.fbla_price===null)return $('checkout-status').textContent='Set the FBLA price on the Snacks tab first.';
 scanning=true;
 try{const d=await rpc('checkout_snack_v2',{p_student_barcode:st,p_snack_barcode:code,p_request_id:crypto.randomUUID(),p_fbla:true});$('checkout-status').textContent='FBLA sale: '+sn.name+' for '+d.charged+' point(s). Balance: '+d.balance;refresh();}
 catch(err){$('checkout-status').textContent='Sale not confirmed: '+err.message;}
 finally{scanning=false;input.focus();}
}
function buttons(){
 const body=$('student-rows');if(!body)return;
 body.querySelectorAll('tr').forEach(tr=>{
  const btn=tr.querySelector('button[data-student-action="checkout"]');
  const actions=tr.querySelector('td.actions');
  if(!btn||!actions||tr.querySelector('[data-fm]'))return;
  for(const [action,label] of [['edit','Edit'],['delete','Delete']]){
   const b=document.createElement('button');b.className='btn smallbtn'+(action==='delete'?' danger':'');
   b.textContent=label;b.dataset.fm=action;b.dataset.sid=btn.dataset.id;
   actions.append(' ',b);
  }
 });
}
async function studentClick(e){
 const btn=e.target.closest('[data-fm]');if(!btn||!ready)return;
 e.preventDefault();e.stopPropagation();
 const tr=btn.closest('tr'),id=Number(btn.dataset.sid),name=tr.cells[0].textContent.trim(),barcode=tr.cells[1].textContent.trim();
 try{
  if(btn.dataset.fm==='edit'){
   const newName=prompt('Student name:',name);if(newName===null)return;
   const newBarcode=prompt('Student ID barcode:',barcode);if(newBarcode===null)return;
   if(!newName.trim()||!newBarcode.trim())return alert('Name and barcode required.');
   await rpc('edit_student_v2',{p_student_id:id,p_barcode:newBarcode.trim(),p_full_name:newName.trim()});
  }else{
   if(!confirm('Permanently remove '+name+'? Unused points will be lost and transaction records anonymized.'))return;
   if(prompt('Type DELETE to confirm:')!=='DELETE')return;
   await rpc('delete_student_v2',{p_student_id:id});
  }
  refresh();
 }catch(err){error(err);}
}
function snackFields(){
 const form=$('snack-form'),panel=document.createElement('div');panel.className='full';
 panel.innerHTML='<div class="formgrid"><div><label>Pack cost ($)</label><input class="field" id="f-pack-cost" type="number" step="0.01" min="0"></div><div><label>Count in pack</label><input class="field" id="f-pack-count" type="number" step="1" min="1"></div><div><label>FBLA price</label><select class="field" id="f-member-price"><option value="">No special price</option><option value="1">1 point</option><option value="2">2 points</option></select></div></div><p class="small">Stock is the actual number of items remaining.</p>';
 form.insertBefore(panel,form.querySelector('button[type="submit"]').parentElement);
 $('snack-rows').addEventListener('click',e=>{
  if(!e.target.closest('[data-snack-action="edit"]'))return;
  setTimeout(()=>{const it=items.find(x=>x.barcode===$('snack-barcode').value);$('f-pack-cost').value=it?.pack_cost??'';$('f-pack-count').value=it?.pack_size??'';$('f-member-price').value=it?.fbla_price??'';},0);
 });
 form.addEventListener('submit',async e=>{
  if(!ready)return;
  e.preventDefault();e.stopImmediatePropagation();
  const barcode=$('snack-barcode').value.trim(),name=$('snack-name').value.trim(),price=Number($('snack-price').value);
  const rawStock=$('snack-stock').value.trim(),rawCost=$('f-pack-cost').value.trim(),rawCount=$('f-pack-count').value.trim(),rawMember=$('f-member-price').value;
  const stock=rawStock===''?null:Number(rawStock),cost=rawCost===''?null:Number(rawCost),count=rawCount===''?null:Number(rawCount),member=rawMember===''?null:Number(rawMember);
  if(!barcode||!name||![1,2].includes(price)||stock!==null&&(!Number.isInteger(stock)||stock<0)||(cost===null)!==(count===null)||cost!==null&&(!Number.isFinite(cost)||cost<0)||count!==null&&(!Number.isInteger(count)||count<=0)||member!==null&&(![1,2].includes(member)||member>price))return alert('Check snack, price, stock, pack cost/count, and FBLA price.');
  try{await rpc('save_snack_v2',{p_barcode:barcode,p_name:name,p_price:price,p_stock:stock,p_pack_cost:cost,p_pack_size:count,p_fbla_price:member});form.reset();refresh();alert('Snack saved.');}catch(err){error(err);}
 },true);
}
function install(){
 if(loaded)return;loaded=true;
 const app=$('app'),nav=app.querySelector('nav'),tab=document.createElement('button');tab.textContent='Finances';nav.appendChild(tab);
 const section=document.createElement('section');section.id='f-panel';section.className='hidden';
 section.innerHTML='<div class="heading-row"><h1>Panther Pantry finances</h1><button id="f-refresh" class="btn">Refresh</button></div><p class="lead">Sales, inventory, and product performance</p><div class="stats">'+[['f-revenue','Revenue from snacks'],['f-profit','Gross profit'],['f-cogs','Cost of goods sold'],['f-margin','Gross margin'],['f-stockcost','Stock at cost'],['f-stockretail','Potential stock revenue'],['f-reloads','Cash reloads recorded'],['f-units','Units sold']].map(([id,title])=>'<div class="card stat"><span>'+title+'</span><strong id="'+id+'">—</strong></div>').join('')+'</div><div class="grid2 equal"><div class="card"><h2>Most popular</h2><p id="f-most">—</p></div><div class="card"><h2>Least popular</h2><p id="f-least">—</p></div></div><section class="card" style="margin-top:18px"><h2>Product performance</h2><div class="tbl-wrap"><table class="tbl"><thead><tr><th>Snack</th><th>Sold</th><th>Revenue</th><th>Gross profit</th><th>Stock</th><th>Unit cost</th></tr></thead><tbody id="f-rows"></tbody></table></div><p class="small" id="f-warning"></p></section><p class="warn" id="f-setup">Checking SQL setup...</p><p class="help-panel">Revenue is recognized on snack sales, not cash reloads. Gross profit excludes operating expenses. Historical costs may be estimates.</p>';
 app.insertBefore(section,app.querySelector('.copyright'));
 tab.addEventListener('click',()=>{app.querySelectorAll('[id^="tab-"]').forEach(x=>x.classList.add('hidden'));nav.querySelectorAll('button').forEach(x=>x.classList.remove('active'));tab.classList.add('active');section.classList.remove('hidden');check();});
 nav.querySelectorAll('button[data-tab]').forEach(x=>x.addEventListener('click',()=>{section.classList.add('hidden');tab.classList.remove('active');}));
 $('f-refresh').addEventListener('click',check);
 const label=document.createElement('label');label.style.margin='14px 0';label.innerHTML='<input id="f-toggle" type="checkbox"> Use FBLA member price for scanned snacks';
 $('student-box').parentElement.insertBefore(label,$('student-box'));$('f-toggle').addEventListener('change',e=>{fbla=e.target.checked;$('scan').focus();});
 $('scan').addEventListener('keydown',scan,true);
 const custom=document.createElement('button');custom.className='btn reload-btn';custom.type='button';custom.innerHTML='Custom<small>$1–$500</small>';$('reload10').parentElement.appendChild(custom);custom.addEventListener('click',custom);
 $('student-rows').addEventListener('click',studentClick,true);
 new MutationObserver(buttons).observe($('student-rows'),{childList:true,subtree:true});buttons();
 snackFields();check();
}
function poll(){if(!loaded&&$('app')&&!$('app').classList.contains('hidden'))install();}
poll();setInterval(poll,1400);
})();
