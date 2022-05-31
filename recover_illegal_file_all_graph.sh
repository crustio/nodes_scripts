#!/bin/bash
basedir=$(cd `dirname $0`; pwd)
tmpfile=$basedir/TMPFILE
declare -A files_size_map
declare -A files_acc_map
declare -A chain_valid_cids

account=$(curl -s http://localhost:12222/api/v0/enclave/id_info | jq -r .account)
if [ x"$account" = x"" ]; then
    echo "ERROR: account cannot be empty!"
    exit 1
fi
echo "INFO: account:$account"

########## Get fetch file condition ##########
# Get register block number
registerBlkCond=""
while true; do
    curl -s -XPOST 'https://crust.indexer.gc.subsquid.io/v4/graphql' --data-raw '{"query": "query MyQuery {\n  substrate_extrinsic(where: {signer: {_eq: \"'$account'\"}, method: {_eq: \"register\"}'$registerBlkCond'}, limit: 100, order_by: {blockNumber: desc}) {\n    substrate_events(where: {method: {_eq: \"RegisterSuccess\"}}) {\n      data(path: \".param1.value\")\n      method\n      blockNumber\n    }\n  }\n}\n"}' -H "content-type: application/json; charset=utf-8" > $tmpfile
    registerBlockNum=$(cat $tmpfile | jq -r '.data.substrate_extrinsic|.[].substrate_events|.[].blockNumber' | head -n 1)
    if [ x"$registerBlockNum" = x"" ]; then
        echo "ERROR: get register block number failed!"
        exit 1
    fi
    curl -s -XPOST 'https://crust.indexer.gc.subsquid.io/v4/graphql' --data-raw '{"query": "query MyQuery {\n  substrate_extrinsic(where: {signer: {_eq: \"'$account'\"}, method: {_eq: \"reportWorks\"}, blockNumber: {_gte: \"'$registerBlockNum'\"}}, limit: 100, order_by: {blockNumber: asc}) {\n    substrate_events(where: {method: {_eq: \"WorksReportSuccess\"}}) {\n      extrinsicArgs(path: \".reportedFilesSize.value\")\n      blockNumber\n    }\n  }\n}\n"}' -H "content-type: application/json; charset=utf-8" > $tmpfile
    registerAFilesSize=$(cat $tmpfile | jq -r '.data.substrate_extrinsic|.[].substrate_events|.[].extrinsicArgs' | head -n 1)
    if [ x"$registerAFilesSize" = x"" ]; then
        echo "ERROR: find register block number failed!"
        exit 1
    fi
    if [ x"$registerAFilesSize" = x"0" ]; then
        break
    fi
    registerBlkCond=",blockNumber:{_lt:"$registerBlockNum"}"
done
echo "register block number:$registerBlockNum"
# Get join group block number
curl -s -XPOST 'https://crust.indexer.gc.subsquid.io/v4/graphql' --data-raw '{"query": "query MyQuery {\n  substrate_extrinsic(where: {signer: {_eq: \"'$account'\"}, method: {_eq: \"joinGroup\"}}, limit: 100, order_by: {blockNumber: desc}) {\n    substrate_events(where: {method: {_eq: \"JoinGroupSuccess\"}}) {\n      data(path: \".param1.value\")\n      method\n      blockNumber\n    }\n  }\n}\n"}' -H "content-type: application/json; charset=utf-8" > $tmpfile
joinGroupBlockNum=$(cat $tmpfile | jq -r '.data.substrate_extrinsic|.[].substrate_events|.[].blockNumber' | head -n 1)
if [ x"$registerBlockNum" = x"" ]; then
    fetchFromBlockNum=$joinGroupBlockNum
elif [ x"$joinGroupBlockNum" = x"" ]; then
    fetchFromBlockNum=$registerBlockNum
else
    if [ $registerBlockNum -gt $joinGroupBlockNum ]; then
        fetchFromBlockNum=$registerBlockNum
    else
        fetchFromBlockNum=$joinGroupBlockNum
    fi
fi
fetchFileCond=""
if [ x"$fetchFromBlockNum" != x"" ]; then
    fetchFileCond="(where:{blockNum_gte:"$fetchFromBlockNum"})"
fi
echo "fetchFileCond:$fetchFileCond"
# Get file from subsquid
echo "INFO: get files from subsquid..."
curl -s -XPOST 'https://app.gc.subsquid.io/beta/crust-v5/003/graphql' --data-raw '{"query": "query MyQuery {\n  accountById(id: \"'$account'\") {\n    workReports'$fetchFileCond' {\n      addedFiles\n      deletedFiles\n    }\n  }\n}"}' -H "content-type: application/json; charset=utf-8" > $tmpfile
if ! cat $tmpfile | jq '.' &>/dev/null; then
    echo "ERROR: get data from subsquid failed, please try later."
    exit 1
fi
j=0
cur_cid=""
for el in $(cat $tmpfile | jq -r ".data.accountById.workReports|.[]|.addedFiles|.[]|.[0:2]|.[]"); do
    if ((j % 2 == 0)); then
        cur_cid=$(echo $el | xxd -r -p)
    else
        files_size_map[$cur_cid]=$el
        acc=${files_acc_map[$cur_cid]}
        if [ x"$acc" = x"" ]; then
            acc=0
        fi
        files_acc_map[$cur_cid]=$((++acc))
    fi
    ((j++))
done
for cid in $(cat $tmpfile | jq -r ".data.accountById.workReports|.[]|.deletedFiles|.[]|.[0]"); do
    cur_cid=$(echo $cid | xxd -r -p)
    files_acc_map[$cur_cid]=$((${files_acc_map[$cur_cid]}-1))
done
for cid in ${!files_size_map[@]}; do
    if [ ${files_acc_map[$cid]} -gt 0 ]; then
        chain_valid_cids[$cid]=${files_size_map[$cid]}
    fi
done
echo "INFO: file number:${#chain_valid_cids[@]}"

########## Get successful reported file size ##########
crust_base_url="http://localhost:12222/api/v0"
params=$(curl -s -XPOST 'https://crust.webapi.subscan.io/api/scan/extrinsics' --header 'Content-Type: application/json' --data-raw '{"jsonrpc":"2.0", "call": "report_works", "module": "swork", "no_params": false, "page": 0, "row": 1, "signed": "signed", "success": true,"address": "'$account'"}' | jq -r .data.extrinsics | jq -r .[0].params | sed 's/\\//g' | jq .)
#success_file_size=$(curl -s -XPOST 'https://crust.indexer.gc.subsquid.io/v4/graphql' --data-raw '{"query": "query MyQuery {\n  substrate_extrinsic(limit: 1, where: {signer: {_eq: \"'$account'\"}, method: {_eq: \"reportWorks\"}}, order_by: {blockNumber: desc}) {\n    substrate_events(where: {method: {_eq: \"WorksReportSuccess\"}}) {\n      method\n    }\n    args\n  }\n}\n"}' -H "content-type: application/json; charset=utf-8" | jq -r '.data.substrate_extrinsic|.[0].args|.[5].value')
if [ x"$params" = x"" ]; then 
    echo "ERROR: get information from subsquid failed, please try again."
    exit 1
fi
success_file_size=$(echo $params | jq .[5].value)
echo "INFO: subsquid reported_file_size:$success_file_size"
# Get local file size
curl -s -XGET "$crust_base_url/file/info_by_type?type=valid" > $tmpfile
#trap "rm $tmpfile" EXIT
repaired_file_size=0
for size in $(cat $tmpfile | jq '.[]|.size'); do
    ((repaired_file_size=repaired_file_size+size))
done
echo "INFO: local file size:$repaired_file_size"
declare -A valid_cids_map
declare -A local_cids_map
for cid in $(cat $tmpfile | jq -r 'keys|.[]'); do
    valid_cids_map[$cid]=0
    local_cids_map[$cid]=0
done
declare -A lost_cids_map
for cid in $(curl -s -XGET "$crust_base_url/file/info_by_type?type=lost" | jq -r 'keys|.[]'); do
    lost_cids_map[$cid]=0
    local_cids_map[$cid]=0
done
echo "INFO: local file number:${#local_cids_map[@]}"
local_less_cids=()
i=0
for cid in ${!chain_valid_cids[@]}; do
    if [ x"${local_cids_map[$cid]}" = x"" ]; then
        local_less_cids[$i]=$cid
        ((i++))
    fi
done
echo "INFO: cids in chain but not in local number:${#local_less_cids[@]}"
i=0
local_more_cids=()
for cid in ${!local_cids_map[@]}; do
    if [ x"${chain_valid_cids[$cid]}" = x"" ]; then
        local_more_cids[$i]=$cid
        ((i++))
    fi
done
echo "INFO: cids in local but not in chain number:${#local_more_cids[@]}"
more_file_size=0
for cid in ${local_more_cids[@]}; do
    info=$(cat $tmpfile | grep $cid)
    if [ x"$info" != x"" ]; then
        t=$(echo $info | awk '{print $6}')
        ((more_file_size=more_file_size+t))
    fi
done
less_file_size=0
for cid in ${local_less_cids[@]}; do
    t=${chain_valid_cids[$cid]}
    ((less_file_size=less_file_size+t))
done
echo "INFO: more file size:$more_file_size, less file size:$less_file_size"
((repaired_file_size=repaired_file_size-more_file_size+less_file_size))
echo "INFO: repaired file size:$repaired_file_size"
if [ $repaired_file_size -ne $success_file_size ]; then
    echo "ERROR: repaired file size not equal to last successful reported file size!"
    exit 1
fi

########## Get latest work report cids ##########
curl -s -XPOST 'https://crust.indexer.gc.subsquid.io/v4/graphql' --data-raw '{"query": "query MyQuery {\n  substrate_extrinsic(where: {signer: {_eq: \"'$account'\"}, method: {_eq: \"reportWorks\"}}, limit: 100, order_by: {blockNumber: desc}) {\n    substrate_events {\n      extrinsicArgs(path: \".addedFiles.value\")\n    }\n  }\n}\n"}' -H "content-type: application/json; charset=utf-8" > $tmpfile
declare -A reported_added_cids
for el in $(cat $tmpfile | jq -r '.data.substrate_extrinsic[0].substrate_events[0].extrinsicArgs|.[]|.[0]'); do
    cid=$(echo $el | xxd -r -p)
    reported_added_cids[$cid]=0
done
curl -s -XPOST 'https://crust.indexer.gc.subsquid.io/v4/graphql' --data-raw '{"query": "query MyQuery {\n  substrate_extrinsic(where: {signer: {_eq: \"'$account'\"}, method: {_eq: \"reportWorks\"}}, limit: 100, order_by: {blockNumber: desc}) {\n    substrate_events {\n      extrinsicArgs(path: \".deletedFiles.value\")\n    }\n  }\n}\n"}' -H "content-type: application/json; charset=utf-8" > $tmpfile
declare -A reported_deleted_cids
for el in $(cat $tmpfile | jq -r '.data.substrate_extrinsic[0].substrate_events[0].extrinsicArgs|.[]|.[0]'); do
    cid=$(echo $el | xxd -r -p)
    reported_deleted_cids[$cid]=0
done

########## Delete invalid files ##########
# Confirm added files
echo "INFO: confirm added files..."
local_rmore_cids=()
for cid in ${!reported_added_cids[@]}; do
    if [ x"${chain_valid_cids[$cid]}" != x"" ]; then
        local_rmore_cids[${#local_rmore_cids[@]}]=$cid
    fi
done
recover_added_data='{"added_files":['
if [ ${#local_rmore_cids[@]} -gt 0 ]; then
    for cid in ${local_rmore_cids[@]}; do
        recover_added_data="${recover_added_data}\"$cid\","
    done
    recover_added_data="${recover_added_data:0:len-1}]}"
    curl -s -XPOST "$crust_base_url/file/recover_illegal" --header 'Content-Type: application/json' --data-raw "$recover_added_data"
fi
# Confirm deleted files
echo "INFO: confirm deleted files..."
local_rless_cids=()
for cid in ${!reported_deleted_cids[@]}; do
    if [ x"${chain_valid_cids[$cid]}" = x"" ]; then
        local_rless_cids[${#local_rless_cids[@]}]=$cid
    fi
done
recover_del_data='{"deleted_files":['
if [ ${#local_rless_cids[@]} -gt 0 ]; then
    for cid in ${local_rless_cids[@]}; do
        recover_del_data="${recover_del_data}\"$cid\","
    done
    recover_del_data="${recover_del_data:0:len-1}]}"
    curl -s -XPOST "$crust_base_url/file/recover_illegal" --header 'Content-Type: application/json' --data-raw "$recover_del_data"
fi

########## Add valid files ##########
lost_cids=($(curl -s -XGET $crust_base_url/file/info_by_type?type=lost | jq -r 'keys|.[]'))
declare -A lost_cids_map
declare -A local_rless_cids
for cid in ${lost_cids[@]}; do
    lost_cids_map[$cid]=0
    if [ x"${local_less_cids[$cid]}" = x"" ]; then
        local_rless_cids[$cid]=0
    fi
done
# Add files
if [ ${#local_rless_cids[@]} -gt 0 ]; then 
    echo "INFO: Add valid files..."
    recover_added_data='{"added_files":['
    for cid in ${local_rless_cids[@]}; do
        #ipfs pin add $cid
        ret_code=$(curl -s -o /dev/null -w "%{http_code}" -XPOST "$crust_base_url/storage/seal_start" --data-raw '{"cid":"'$cid'"}')
        if [ $ret_code -ne 200 ]; then
            curl -s -XPOST "$crust_base_url/file/recover_illegal" --header 'Content-Type: application/json' --data-raw '{"deleted_files":["'$cid'"]}'
            curl -s -XPOST "$crust_base_url/storage/delete" --data-raw '{"cid": "'$cid'"}'
        fi
        ret_code=$(curl -s -o /dev/null -w "%{http_code}" -XPOST "http://localhost:5001/api/v0/pin/add?arg=$cid")
        if [ $ret_code -ne 200 ]; then
            echo "ERROR: Add file failed, please try again"
            exit 1
        fi
        recover_added_data="${recover_added_data}\"$cid\","
    done
    recover_added_data="${recover_added_data:0:len-1}]}"
    curl -s -XPOST "$crust_base_url/file/recover_illegal" --header 'Content-Type: application/json' --data-raw "$recover_added_data"
    echo "INFO: Done"
fi
echo "INFO: recover successfully!"
