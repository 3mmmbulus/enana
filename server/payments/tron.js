'use strict';
const crypto=require('node:crypto');
const USDT='TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t';
const TRANSFER='ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';
const ALPHABET='123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
function hash(b){return crypto.createHash('sha256').update(b).digest()}
function decodeAddress(address){
 if(typeof address!=='string'||!/^T[1-9A-HJ-NP-Za-km-z]{33}$/.test(address))throw Error('invalid_tron_address');
 let value=0n;for(const ch of address)value=value*58n+BigInt(ALPHABET.indexOf(ch));
 const bytes=Buffer.from(value.toString(16).padStart(50,'0'),'hex');
 if(bytes.length!==25||bytes[0]!==0x41||!crypto.timingSafeEqual(bytes.subarray(21),hash(hash(bytes.subarray(0,21))).subarray(0,4)))throw Error('invalid_tron_checksum');
 return bytes.subarray(0,21);
}
function encodeAddress(hex){const raw=Buffer.from('41'+hex,'hex');if(raw.length!==21)throw Error('invalid_address_hex');const bytes=Buffer.concat([raw,hash(hash(raw)).subarray(0,4)]);let n=BigInt('0x'+bytes.toString('hex')),out='';while(n){out=ALPHABET[Number(n%58n)]+out;n/=58n}return out}
function validateAddresses(values){if(!Array.isArray(values)||!values.length||values.length>20)throw Error('invalid_address_pool');const unique=new Set();for(const a of values){decodeAddress(a);if(unique.has(a))throw Error('duplicate_address');unique.add(a)}return [...unique]}
function hex(v){return typeof v==='string'?v.replace(/^0x/,'').toLowerCase():''}
function receiptTransfers(receipt,txid,solidHeight,addresses){
 if(!/^[a-f0-9]{64}$/.test(txid)||!Number.isSafeInteger(solidHeight)||solidHeight<1)throw Error('invalid_confirmation_context');
 if(!receipt||hex(receipt.id)!==txid||receipt.receipt?.result!=='SUCCESS'||!Number.isSafeInteger(receipt.blockNumber)||receipt.blockNumber<1||receipt.blockNumber>solidHeight||!Number.isSafeInteger(receipt.blockTimeStamp)||receipt.blockTimeStamp<1||!Array.isArray(receipt.log))throw Error('unconfirmed_or_failed_receipt');
 const owned=new Map(addresses.map(a=>[decodeAddress(a).subarray(1).toString('hex'),a])),contract=decodeAddress(USDT).subarray(1).toString('hex'),events=[];
 for(let index=0;index<receipt.log.length;index++){
  const log=receipt.log[index],topics=log.topics?.map(hex),token=hex(log.address).replace(/^41(?=[a-f0-9]{40}$)/,'');
  if(token!==contract||!topics||topics.length!==3||topics[0]!==TRANSFER||!/^0{24}[a-f0-9]{40}$/.test(topics[1])||!/^0{24}[a-f0-9]{40}$/.test(topics[2])||!/^[a-f0-9]{64}$/.test(hex(log.data)))continue;
  const address=owned.get(topics[2].slice(-40)),amount=BigInt('0x'+hex(log.data));
  if(!address||amount<1n||amount>9000000000000n)continue;
  events.push({event_key:txid+':'+index,address,amount:Number(amount),chain_at:Math.floor(receipt.blockTimeStamp/1000)});
 }
 return events;
}
module.exports={USDT,TRANSFER,decodeAddress,encodeAddress,validateAddresses,receiptTransfers};
