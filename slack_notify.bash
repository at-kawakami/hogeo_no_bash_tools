#!/bin/bash
# source: https://qiita.com/tt2004d/items/50d79d1569c0ace118d6

SLACKENDPOINT="https://hooks.slack.com/services/xxxxxxxxx/xxxxxxxxx/xxxxxxxxxxxxxxxxxxxxxxxx"
MESSAGEFILE=$(mktemp -t webhooks.XXXXX)
trap "
rm ${MESSAGEFILE}
" 0

while getopts c:i:n:m: opts
do
    case $opts in
        c)
            CHANNEL=$OPTARG
            ;;
        i)
            FACEICON=$OPTARG
            ;;
        n)
            BOTNAME=$OPTARG
            ;;
        m)
            MESSAGE=$OPTARG"\n"
            ;;
        \?)
            usage_exit
            ;;
    esac
done

CHANNEL=${CHANNEL:-"#pj-hoge"}
BOTNAME=${BOTNAME:-"Ansible auto deploy"}
FACEICON=${FACEICON:-":man-raising-hand:"}
MESSAGE=${MESSAGE:-""}

if [ -p /dev/stdin ] ; then
    #改行コードをslack用に変換
  tr '\n' '\r' | sed 's/'"$(printf '\r')"'/\\n/g' > ${MESSAGEFILE}
else
  echo "nothing stdin"
  exit 1
fi

WEBMESSAGE='```'`cat ${MESSAGEFILE}`'```'

curl -s -S -X POST \
--data-urlencode "payload={\"channel\": \"${CHANNEL}\", \"username\": \"${BOTNAME}\", \"icon_emoji\": \"${FACEICON}\", \"text\": \"${MESSAGE}${WEBMESSAGE}\" }" $SLACKENDPOINT
