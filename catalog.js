(function catalogAddon(){
'use strict';
const cfg=window.SNACK_PASS_CONFIG||{};
if(!window.supabase||!cfg.supabaseUrl||!cfg.supabaseAnonKey)return;
const db=window.supabase.createClient(cfg.supabaseUrl,cfg.supabaseAnonKey);
const $=id=>document.getElementById(id);
const products=[
['Pringles',27,13.98,1],['Nerd Clusters',24,29.53,2],['Rice Krispies',40,10.99,1],
['Mothers Circus',30,15.64,1],['Miss Vickies',28,18.49,2],['Goldfish',30,15.99,1],
['Chip Pack',40,22.43,2],['Gushers',42,22.95,2],['Welches',80,16,1],
['Veggie Straw',24,32,2],['Oreo',60,18.65,1],['Skinny Pop',30,18.20,1],
['Yoggies',30,23.99,1],['Skittles and Starbursts',30,27.99,2],['Blakes Bars',24,29.99,2]
];
let attached=false;
const norm=s=>String(s||'').toLowerCase().replace(/[^a-z0-9]/g,'');
async function call(name,args){
 const {data,error}=await db.rpc(name,args);
 if(error)throw error;
 return data;
}
function reportError(e){alert(e.message||String(e));}
function refresh(){
 $('refresh-activity')?.click();
 $('f-refresh')?.click();
}
function setup(){
 if(attached||!$('snack-form')||!$('snack-rows')||!$('f-pack-cost'))return;
 attached=true;
 const form=$('snack-form'),container=document.createElement('div');
 container.className='full';
 const label=document.createElement('label');label.textContent='Panther Pantry product preset';
 const select=document.createElement('select');select.className='field';
 select.append(new Option('Choose a product to fill costs and selling price',''));
 for(let i=0;i<products.length;i++){
  const p=products[i];
  select.append(new Option(p[0]+' | $'+(p[2]/p[1]).toFixed(3)+' unit cost | $'+p[3]+' selling price',String(i)));
 }
 const hint=document.createElement('p');hint.className='small';
 hint.textContent='Presets fill the pack price, count, and sale price. Scan the real barcode and enter the actual stock quantity. Existing barcodes will not be overwritten automatically.';
 container.append(label,select,hint);
 form.insertBefore(container,form.firstElementChild);
 select.addEventListener('change',async()=>{
  if(select.value==='')return;
  const p=products[Number(select.value)];
  $('snack-name').value=p[0];$('snack-price').value=p[3];
  $('f-pack-count').value=p[1];$('f-pack-cost').value=p[2].toFixed(2);
  const {data,error}=await db.from('snacks').select('barcode,name,stock,fbla_price').limit(2000);
  if(error)return;
  const match=(data||[]).find(x=>norm(x.name)===norm(p[0]));
  if(match){$('snack-barcode').value=match.barcode;$('snack-stock').value=match.stock??'';$('f-member-price').value=match.fbla_price??'';}
  else {$('snack-barcode').value='';$('snack-stock').value='';$('f-member-price').value='';}
 });
 const body=$('snack-rows');
 function addButtons(){
  body.querySelectorAll('tr').forEach(row=>{
   const original=row.querySelector('[data-snack-action="edit"]');
   const cell=row.querySelector('td.actions');
   if(!original||!cell||row.querySelector('[data-remove-snack]'))return;
   const b=document.createElement('button');
   b.type='button';b.className='btn smallbtn danger';b.textContent='Remove';
   b.setAttribute('data-remove-snack','true');
   cell.append(' ',b);
  });
 }
 body.addEventListener('click',async event=>{
  const button=event.target.closest('button[data-remove-snack]');
  if(!button)return;
  event.preventDefault();event.stopImmediatePropagation();
  const row=button.closest('tr'),name=row.cells[0].textContent.trim(),barcode=row.cells[1].textContent.trim();
  if(!confirm('Permanently remove '+name+'? Previous purchase amounts will remain in reports, but the product disappears from the inventory.'))return;
  if(prompt('Type REMOVE to confirm:')!=='REMOVE')return;
  button.disabled=true;
  try{
   const result=await call('remove_snack_v3',{p_barcode:barcode});
   refresh();alert(result.name+' removed. '+result.sales_preserved+' past purchases preserved.');
  }catch(e){button.disabled=false;reportError(e);}
 },true);
 new MutationObserver(addButtons).observe(body,{childList:true,subtree:true});
 addButtons();
}
function poll(){if(!attached&&$('app')&&!$('app').classList.contains('hidden'))setup();}
poll();setInterval(poll,1300);
})();
