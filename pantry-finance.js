(()=>{
'use strict';
const cfg=window.SNACK_PASS_CONFIG||{};if(!window.supabase||!cfg.supabaseUrl||!cfg.supabaseAnonKey)return;
const db=window.supabase.createClient(cfg.supabaseUrl,cfg.supabaseAnonKey);
const $=id=>document.getElementById(id);
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const usd=n=>'$'+Number(n||0).toFixed(2);
let financeLoaded=false,financeBusy=false;
const baseCatalog=[['Pringles',27,13.98,1],['Nerd Clusters',24,29.53,2],['Rice Krispies',40,10.99,1],['Mothers Circus',30,15.64,1],['Miss Vickies',28,18.49,2],['Goldfish',30,15.99,1],['Chip Pack',40,22.43,2],['Gushers',42,22.95,2],['Welches',80,16,1],['Veggie Straw',24,32,2],['Oreo',60,18.65,1],['Skinny Pop',30,18.20,1],['Yoggies',30,23.99,1],['Skittles and Starbursts',30,27.99,2],['Blakes Bars',24,29.99,2]];
const norm=s=>String(s||'').toLowerCase().replace(/[^a-z0-9]/g,'');
const ali={nerdsclusters:'nerdclusters',nerdsgummyclusters:'nerdclusters',ricekrispiestreats:'ricekrispies',motherscircuscookies:'motherscircus',welchs:'welches',welchsfruitsnacks:'welches',veggiestraws:'veggiestraw',oreocookies:'oreo',blakesseedbars:'blakesbars'};
function lookup(name){return window.PANTRY_PRICE_BOOK?.find(name)||baseCatalog.find(x=>norm(x[0])===norm(name));}
function showTab(){
 if(!window.PANTRY_CAN_VIEW_FINANCES)return;
 ['checkout','students','snacks','activity'].forEach(id=>$('tab-'+id).classList.add('hidden'));
 $('tab-finances').classList.remove('hidden');
 document.querySelectorAll('nav button').forEach(x=>x.classList.toggle('active',x.dataset.tab==='finances'));
 if(!financeLoaded)load();
}
document.querySelector('[data-tab="finances"]').addEventListener('click',showTab);
document.querySelectorAll('nav button[data-tab]').forEach(x=>{
 if(x.dataset.tab!=='finances')x.addEventListener('click',()=>$('tab-finances').classList.add('hidden'));
});
async function load(){
 if(!window.PANTRY_CAN_VIEW_FINANCES)return;
 if(financeBusy)return;
 financeBusy=true;$('finance-note').textContent='Loading latest totals...';
 try{
 const [financial,stock]=await Promise.all([
  db.rpc('get_snack_finances'),
  db.from('snacks').select('name,barcode,stock,pack_cost,pack_size,price').limit(1000)
 ]);
 if(financial.error)throw financial.error;
 if(stock.error)throw stock.error;
 const f=financial.data||{},items=stock.data||[];
 const summary={
 'finance-revenue':usd(f.sales_revenue),'finance-profit':usd(f.gross_profit),
 'finance-cogs':usd(f.cost_of_goods),'finance-margin':Number(f.sales_revenue)>0?(Number(f.gross_profit)/Number(f.sales_revenue)*100).toFixed(1)+'%':'0%',
 'finance-reloads':usd(f.reload_cash),'finance-units':String(f.units_sold)
 };
 for(const [k,v] of Object.entries(summary))$(k).textContent=v;
 const results=(f.products||[]);
 $('finance-most').textContent=results.filter(x=>x.sold>0).slice(0,5).map(x=>x.name+' ('+x.sold+')').join(', ')||'No recorded sales';
 $('finance-least').textContent=[...results].sort((a,b)=>a.sold-b.sold).slice(0,5).map(x=>x.name+' ('+x.sold+')').join(', ')||'No products';
 let costValue=0,retailValue=0,untracked=0;
 for(const item of items){
  const preset=lookup(item.name);
  const qty=item.pack_size??preset?.[1]??null,cost=item.pack_cost??preset?.[2]??null;
  if(item.stock===null||qty===null||cost===null){untracked++;continue;}
  costValue+=item.stock*cost/qty;
  retailValue+=item.stock*item.price;
 }
 $('finance-stockcost').textContent=usd(costValue);
 $('finance-stockretail').textContent=usd(retailValue);
 const used=new Set();
 const tableRows=baseCatalog.map(p=>{
  const existing=items.find(x=>lookup(x.name)?.[0]===p[0]);
  if(existing)used.add(existing.barcode);
  const totals=existing?results.find(x=>x.barcode===existing.barcode):null;
  const cost=(existing?.pack_cost??p[2])/(existing?.pack_size??p[1]);
  const sold=totals?.sold??0;
  return '<tr><td>'+esc(p[0])+'</td><td>$'+cost.toFixed(3)+'</td><td>'+usd(existing?.price??p[3])+'</td><td>'+(existing?.pack_size??p[1])+'</td><td>'+(existing?(existing.stock??'Untracked'):'Not registered')+'</td><td>'+sold+'</td><td>'+usd(totals?.revenue)+'</td><td>'+usd(totals?.gross_profit)+'</td></tr>';
 });
 for(const item of items.filter(x=>!used.has(x.barcode))){
  const result=results.find(x=>x.barcode===item.barcode);
  const known=lookup(item.name);
  const qty=item.pack_size??known?.[1],total=item.pack_cost??known?.[2];
  tableRows.push('<tr><td>'+esc(item.name)+'</td><td>'+(qty&&total!==null&&total!==undefined?'$'+(total/qty).toFixed(3):'Not provided')+'</td><td>'+usd(item.price)+'</td><td>'+(qty??'—')+'</td><td>'+(item.stock??'Untracked')+'</td><td>'+(result?.sold??0)+'</td><td>'+usd(result?.revenue)+'</td><td>'+usd(result?.gross_profit)+'</td></tr>');
 }
 $('finance-rows').innerHTML=tableRows.join('');
 $('finance-note').textContent='All 15 supplied unit costs are displayed. '+(untracked?untracked+' registered products lack actual stock or cost, so inventory totals are incomplete. ':'')+(f.estimated_legacy_sales?f.estimated_legacy_sales+' historical purchases use estimated current unit costs. ':'')+(f.unknown_cost_sales?f.unknown_cost_sales+' purchases have no cost snapshot in Supabase.':'');
 financeLoaded=true;
 }catch(e){$('finance-note').textContent='Could not load finances: '+e.message+'. Check upgrade_finance.sql and upgrade_activity_inventory.sql.';}
 finally{financeBusy=false;}
}
$('finance-refresh').addEventListener('click',load);
window.addEventListener('pantry-updated',()=>{financeLoaded=false;if(!$('tab-finances').classList.contains('hidden'))load();});
})();
