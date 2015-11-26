#!/bin/sh

app1="mysql"
app2="gitlab-redis"
app3="gitlab"
app4="redmine"
app5="jenkins"
app6="apache"

for i in `seq 1 6`
do
	eval c="ci_\$app${i}"
	rslt=`docker ps | grep -e "${c}$"`
	if [ -z "$rslt" ]
	then
		docker start ${c}
		sleep 10
	fi
done
