#!/bin/bash
##Cloudformation User data configuration script
IPADDRESS=`curl http://169.254.169.254/latest/meta-data/public-ipv4`
ACCOUNT_ID="$1"
REGION="$2"
ADMIN_ID="$3"
PASSWORD="$4"
EMAIL_ID="$5"
RDS_ENDPOINT="$6"
REDSHIFT_ENDPOINT="$7"
REDSHIFT_IAM_ARN="$8"
RDS_DBIDENTIFIER="$9"
RDS_DATABASE="${10}"
REDSHIFT_CLUSTERIDENTIFIER="${11}"
REDSHIFT_DATABASE="${12}"
ELASTICSEARCHEP="${13}"
BUCKET="${14}"
STACKID="${15}"
STACKPART="${16}"
STACKNAME="${17}"
WAITCONDITION="${18}"
STREAMNAME="${19}"
CLOUDTRAIL="${20}"
REDSHIFTARN="arn:aws:redshift:${REGION}:${ACCOUNT_ID}:cluster:${REDSHIFT_CLUSTERIDENTIFIER}"
WORKERGROUP="datalakeworkergroup-${ACCOUNT_ID}-${STACKPART}"
TASKRUNNER="datalaketaskrunner-${ACCOUNT_ID}-${STACKPART}"

mkdir -p /var/www/html; chown -R apache:apache /var/www/html;
aws configure set default.region ${REGION};

#Instance tagging
instanceid=`curl http://169.254.169.254/latest/meta-data/instance-id`
aws ec2 create-tags --resources ${instanceid} --tags 'Key'="Name",'Value'="datalake-webserver-${ACCOUNT_ID}-${STACKPART}" --region ${REGION}
aws ec2 create-tags --resources ${instanceid} --tags 'Key'="solution",'Value'="datalake-${ACCOUNT_ID}-${STACKPART}" --region ${REGION}


setenforce 0;chkconfig httpd on;chkconfig mysqld on;
RDSHOST=(${RDS_ENDPOINT//:/ })

aws datapipeline create-default-roles;

#Mysql configuration
/usr/bin/mysql_secure_installation<<EOF

y
${PASSWORD}
${PASSWORD}
y
y
y
y
EOF


mysql -u ${ADMIN_ID} -p${PASSWORD} --host "${RDSHOST[0]}" "${RDS_DATABASE}" -e "CREATE TABLE IF NOT EXISTS ${RDS_DATABASE}.user(username varchar(200),password varchar(200), PRIMARY KEY (username));"
mysql -u ${ADMIN_ID} -p${PASSWORD} --host "${RDSHOST[0]}" "${RDS_DATABASE}" -e "CREATE TABLE IF NOT EXISTS ${RDS_DATABASE}.buckets(bucketname varchar(200),statementid varchar(200), PRIMARY KEY (bucketname));"
mysql -u ${ADMIN_ID} -p${PASSWORD} --host "${RDSHOST[0]}" "${RDS_DATABASE}" -e "INSERT INTO ${RDS_DATABASE}.user(username,password) VALUES ('${ADMIN_ID}',MD5('${PASSWORD}'));"


if ! aws s3 cp s3://${BUCKET}/multiAZ/instance.active instance.active --region ${REGION} --quiet --sse AES256
then
# Setup catalog lambda code
wget -A.zip https://github.com/akshay-ashok/cloudwick-datalake/raw/datalake-customize/scripts/lambdas/writetoES.zip; mkdir -p /var/www/html/lambes; unzip writetoES.zip -d /var/www/html/lambes; sed -ie "s|oldelasticsearchep|${ELASTICSEARCHEP}|g" /var/www/html/lambes/writetoES/lambda_function.py; rm -rf writetoES.zip;cd /var/www/html/lambes/writetoES;zip -r writetoESX.zip *;aws s3 cp writetoESX.zip s3://$BUCKET/lambdas/writetoESX.zip --region $REGION --sse AES256;

/opt/aws/bin/cfn-signal -e 0 ${WAITCONDITION}
echo "FirstRun-Lambda-signal-check"
fi
##########WebApp configuration########################################
wget -A.zip https://github.com/akshay-ashok/cloudwick-datalake/raw/datalake-customize/scripts/web/datalake.zip; unzip datalake.zip -d /var/www/html; chmod 777 /var/www/html/home/welcome*;
rm -rf /etc/php.ini; mv /var/www/html/configurations/php.ini /etc/php.ini;chown apache:apache /etc/php.ini; chown -R apache:apache /var/www/html;service httpd restart;



#Zeppelin configuration
wget -A.tgz http://apache.claz.org/zeppelin/zeppelin-0.7.0/zeppelin-0.7.0-bin-all.tgz; mkdir -p /var/www/html/zeppelin; tar -xf zeppelin-0.7.0-bin-all.tgz -C /var/www/html/zeppelin; chown -R apache /var/www/html/zeppelin;/var/www/html/zeppelin/zeppelin-0.7.0-bin-all/bin/zeppelin-daemon.sh start


if ! aws s3 cp s3://${BUCKET}/multiAZ/instance.active instance.active --region ${REGION} --quiet --sse AES256
then
#Create ElasticSearch Indices
curl -XPUT https://${ELASTICSEARCHEP}/metadata-store -H "Content-Type: application/json" --data @/var/www/html/configurations/kibana/mappings/metadata-store-mapping.json;
curl -XPUT https://${ELASTICSEARCHEP}/cloudtraillogs -H "Content-Type: application/json" --data @/var/www/html/configurations/kibana/mappings/cloudtraillogs-mapping.json;
curl -XPUT https://${ELASTICSEARCHEP}/datalakedeliverystream -H "Content-Type: application/json" --data @/var/www/html/configurations/kibana/mappings/kinesis-firehose-mapping.json;
echo "FirstRun-ElasticsearchIndexCreation-check"
fi

######TaskRunner#######################################################
mkdir -p /home/ec2-user/TaskRunner; wget -A.jar https://github.com/akshay-ashok/cloudwick-datalake/raw/datalake-customize/scripts/resources/TaskRunner-1.0.jar; mv TaskRunner-1.0.jar /home/ec2-user/TaskRunner/.; cd /home/ec2-user/TaskRunner; java -jar TaskRunner-1.0.jar --workerGroup=${WORKERGROUP} --region=${REGION} --logUri=s3://${BUCKET}/TaskRunnerLogs --taskrunnerId ${TASKRUNNER} > TaskRunner.out 2>&1 < /dev/null &


cat <<EOT >> /var/www/html/root/datalake.ini
[defaults]
version="latest"
region="${REGION}"
accountid="${ACCOUNT_ID}"
adminid="${ADMIN_ID}"
password="${PASSWORD}"
email="${EMAIL_ID}"
ipaddress="${IPADDRESS}"

[stack]
stackid="${STACKID}"
stackname="${STACKNAME}"

[rds]
dbinstanceidentifier="${RDS_DBIDENTIFIER}"
endpoint="${RDS_ENDPOINT}:3306"
database="${RDS_DATABASE}"

[redshift]
clusteridentifier="${REDSHIFT_CLUSTERIDENTIFIER}"
endpoint="${REDSHIFT_ENDPOINT}:5439"
iamrolearn="${REDSHIFT_IAM_ARN}"
database="${REDSHIFT_DATABASE}"

[elasticsearch]
kibana="https://${ELASTICSEARCHEP}/_plugin/kibana/"
elasticsearch="${ELASTICSEARCHEP}"

[s3]
bucket="${BUCKET}"
arn="arn:aws:s3:${REGION}:${ACCOUNT_ID}:${BUCKET}"

[kinesis]
streamname="${STREAMNAME}"

[cloudtrail]
cloudtrailname="${CLOUDTRAIL}"

EOT

chown -R apache:apache /var/www/

if ! aws s3 cp s3://${BUCKET}/multiAZ/instance.active instance.active --region ${REGION} --quiet --sse AES256
then
#attach iam role to redshift
curl http://${IPADDRESS}/scripts/attach-iam-role-to-redshift.php;
echo "FirstRun-RedshiftRoleModify-check"
fi

#Sending out email to the Administrator
if ! aws s3 cp s3://${BUCKET}/multiAZ/instance.active instance.active --region ${REGION} --quiet --sse AES256
then
  curl http://${IPADDRESS}/scripts/send-completion-email.php --data "region=${REGION}&username=${ADMIN_ID}&email=${EMAIL_ID}&ip=${IPADDRESS}&password=${PASSWORD}";
  echo "FirstRun-Email-check"
else
  curl http://${IPADDRESS}/scripts/send-completion-email.php --data "region=${REGION}&username=${ADMIN_ID}&email=${EMAIL_ID}&ip=${IPADDRESS}&password=${PASSWORD}";
  echo "Failover-Email-check"
fi
##Autoscale sync section
echo ${IPADDRESS} > /home/ec2-user/instance.active
chown ec2-user:ec2-user /home/ec2-user/instance.active
aws s3 cp /home/ec2-user/instance.active s3://$BUCKET/multiAZ/instance.active --region ${REGION} --sse AES256
