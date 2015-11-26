#!/bin/sh

if [ $# -ne 4 ]
then
	echo "Usage: Argment [mysql password] [redmine DB password] [gitlab DB password] [gitlab security db keybase]"
	exit 1
fi
#コマンド実行パス（このパスをもとにディレクトリ作成、Apache httpd.confの設定）
pdir=$(cd $(dirname $0); pwd)

mysqlpwd=$1
redminepwd=$2
gitlabpwd=$3
gitlab_seckey=$4

#applications name
app1="mysql"
app2="redmine"
app3="gitlab"
app4="gitlab-redis"
app5="jenkins"
app6="apache"

#image download
images1="mysql"
images2="sameersbn/redmine"
images3="sameersbn/gitlab"
images4="sameersbn/redis"
images5="jenkins"
images6="bitnami/apache"

#dockerコンテナが動いている場合は停止する
a=`docker ps | grep ${images6} | awk '{print $1}'`
if [ -n "${a}" ]
then
	docker kill ${a}
fi
for i in `seq 6 -1 1`
do
	eval c="ci_\$app${i}"
	rslt=`docker ps | grep -e "${c}$"`
	if [ -n "$rslt" ]
	then
		docker kill $c
	fi
done

#すでにコンテナがある場合は、削除する。
for i in `seq 1 6`
do
	eval c="ci_\$app${i}"
	rslt=`docker ps | grep -e "${c}$"`
	if [ -n "$rslt" ]
	then
		docker rm $c
	fi
done


#すでにディレクトリがある場合は削除する
if [ -d ${pdir}/ci/ ] 
then
	rm -rf ${pdir}/ci/
fi

#永続的データ格納先ディレクトリの作成
for i in `seq 1 6`
do
	eval dir="${pdir}/ci/\$app${i}"
	mkdir -p ${dir}
done
eval mysql_dir="${pdir}/ci/\${app1}"
eval redmine_dir="${pdir}/ci/\${app2}"
eval gitlab_dir="${pdir}/ci/\${app3}"
eval redis_dir="${pdir}/ci/\${app4}"
eval jenkins_dir="${pdir}/ci/\${app5}"
eval apache_dir="${pdir}/ci/\${app6}"

#image download
for i in `seq 1 6`
do
	eval img="\$images$i"
	rslt=`docker images | grep $img`
	if [ -z "$rslt" ]
	then
		docker pull ${img}:latest
	fi
done


#(0)apache を ReverseProxyにするためmod_proxy_htmlを追加する→apache_rp というイメージ名にする。
#apache_rpがある場合は削除してから作る
rslt=`docker images | grep apache_rp`
if [ -n "$rslt" ]
then
	docker rmi apache_rp
fi
docker run -d --rm=false -v ${apache_dir}/app:/app -v ${apache_dir}/conf:/bitnami/apache/conf -v ${apache_dir}/logs:/bitnami/apache/logs -p 80:80 -p 443:443 ${images6} 

a=`docker ps | grep ${images6} | awk '{print $1}'`
docker exec -it ${a} apt-get -y update
docker exec -it ${a} sudo apt-get -y install libapache2-mod-proxy-html
docker exec -it ${a} apt-get -y install libxml2-dev
docker exec ${a} ln -s /usr/lib/apache2/modules/mod_proxy_html.so /opt/bitnami/apache2/modules/
docker exec ${a} ln -s /usr/lib/apache2/modules/mod_xml2enc.so /opt/bitnami/apache2/modules/
docker commit ${a} apache_rp
docker stop ${a}
docker rm ${a}

if [ -f ${pdir}/httpd.conf_ ]
then
	cp ${pdir}/httpd.conf_ ${apache_dir}/conf/httpd.conf
fi

#(1)mysql
docker run --name=ci_mysql -d -v ${mysql_dir}:/var/lib/mysql -e MYSQL_ROOT_PASSWORD=${mysqlpwd} mysql:latest
sleep 30

## redmine
docker exec ci_mysql mysql -u root -p${mysqlpwd} -s -e "CREATE USER 'redmine'@'%.%.%.%' IDENTIFIED BY '${redminepwd}'; CREATE DATABASE IF NOT EXISTS redmine_production DEFAULT CHARACTER SET utf8 COLLATE utf8_unicode_ci; GRANT SELECT, LOCK TABLES, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER ON redmine_production.* TO 'redmine'@'%.%.%.%';"

## gitlab
docker exec ci_mysql mysql -u root -p${mysqlpwd} -s -e "CREATE USER 'gitlab'@'%.%.%.%' IDENTIFIED BY '${gitlabpwd}'; CREATE DATABASE IF NOT EXISTS gitlabhq_production DEFAULT CHARACTER SET utf8 COLLATE utf8_unicode_ci; GRANT ALL PRIVILEGES ON gitlabhq_production.* TO 'gitlab'@'%.%.%.%';"

#(2)redis & gitlab
docker run --name=ci_gitlab-redis -d -v ${redis_dir}:/var/lib/redis sameersbn/redis:latest
sleep 30
docker run --name=ci_gitlab -d --link ci_gitlab-redis:redisio --link ci_mysql:mysql -e DB_HOST=mysql -e DB_TYPE=mysql -e DB_NAME=gitlabhq_production -e DB_USER=gitlab -e DB_PASS=${gitlabpwd} -e GITLAB_SECRETS_DB_KEY_BASE=${gitlab_seckey} -v ${gitlab_dir}:/home/git/data sameersbn/gitlab:latest
sleep 30

#(3)redmine
docker run --name=ci_redmine -it -d --link ci_mysql:mysql --link ci_gitlab:ci_gitlab -e DB_HOST=ci_mysql -e DB_NAME=redmine_production -e DB_USER=redmine -e DB_PASS=${redminepwd} -e DB_TYPE=mysql -v ${redmine_dir}:/home/redmine/data sameersbn/redmine:latest
sleep 30

#(4)jenkins
docker run --name=ci_jenkins --link=ci_gitlab:ci_gitlab --link=ci_redmine:ci_redmine -v ${jenkins_dir}:/var/jenkins_home jenkins:latest --prefix=/jenkins/ &
sleep 30

#(5)apache
docker run --name=ci_apache --link=ci_redmine:ci_redmine --link=ci_jenkins:ci_jenkins --link=ci_gitlab:ci_gitlab -v ${apache_dir}/app:/app -v ${apache_dir}/conf:/bitnami/apache/conf -v ${apache_dir}/logs:/bitnami/apache/logs -p 80:80 -p 443:443 apache_rp &

