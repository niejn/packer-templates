#!/bin/bash
#
# Copyright (c) 2019 by Delphix. All rights reserved.
#
# This file is managed by Ansible. Don't make changes here - they will be overwritten.

STARTTIME=$(date +%s)
NOW=$(date +"%m-%d-%Y %T")

function ENDTIME {
	ENDTIME=$(date +%s)
	echo "It took $(($ENDTIME - $STARTTIME)) seconds to complete ${SCRIPT}"
}

function ERROR {
	ENDTIME
	mv ~/Desktop/WAIT ~/Desktop/ERROR
	exit 1
}

function READY {
	ENDTIME
	echo "Script finished Successfully"
	mv ~/Desktop/WAIT ~/Desktop/READY
	touch ~/STAGED
}

function STAGED {
	echo "Running STAGED function"
	~/tw_ddp_ready -c ~/tw_prep_conf.txt

	[[ ${PIPESTATUS[0]} -ne 0 ]] && ERROR

	ssh -t centos@tooling "rm -Rf /tmp/dev /tmp/test /tmp/prod && git clone /var/lib/jenkins/app_repo.git /tmp/dev && git clone /var/lib/jenkins/app_repo.git /tmp/test && git clone /var/lib/jenkins/app_repo.git /tmp/prod"
	[[ ${PIPESTATUS[0]} -ne 0 ]] && ERROR

	ssh -t centos@tooling snap_prod_refresh_mm --config snap_conf.txt &

	ssh -t centos@tooling ansible-playbook /tmp/prod/ansible/deploy.yaml -e git_branch=origin/production -e git_commit=x -e sdlc_env=PROD --limit prodweb
	[[ ${PIPESTATUS[0]} -ne 0 ]] && ERROR
	ssh -t centos@tooling ansible-playbook /tmp/test/ansible/deploy.yaml -e git_branch=origin/master -e git_commit=x -e sdlc_env=QA --limit testweb
	[[ ${PIPESTATUS[0]} -ne 0 ]] && ERROR
	ssh -t centos@tooling ansible-playbook /tmp/dev/ansible/deploy.yaml -e git_branch=origin/develop -e git_commit=x -e sdlc_env=DEV --limit devweb
	[[ ${PIPESTATUS[0]} -ne 0 ]] && ERROR

	for job in `jobs -p`
	do
	echo $job
	wait $job || let "FAIL+=1"
	done

	[[ -n "${FAIL}" ]] && ERROR

}

function PRISTINE {
	echo "Running PRISTINE function"
	cd ~
	~/tw_provision -c ~/tw_provision_config.txt

	[[ ${PIPESTATUS[0]} -ne 0 ]] && ERROR
	
	# MVN_YARN
	PREPARE_PROD
	PREPARE_LOWER
	
}

function MVN_YARN {
	ssh -t centos@tooling "rm -Rf /tmp/dev /tmp/test /tmp/prod && git clone /var/lib/jenkins/app_repo.git /tmp/dev && git clone /var/lib/jenkins/app_repo.git /tmp/test && git clone /var/lib/jenkins/app_repo.git /tmp/prod"
	[[ ${PIPESTATUS[0]} -ne 0 ]] && ERROR

	ssh -t centos@tooling "sudo rm -Rf /tmp/jenkins_dev && git clone /var/lib/jenkins/app_repo.git /tmp/jenkins_dev && sudo chown -R jenkins.jenkins /tmp/jenkins_dev && sudo -u jenkins bash -c 'cd /tmp/jenkins_dev && mvn clean && cd client && yarn install'"
	[[ ${PIPESTATUS[0]} -ne 0 ]] && ERROR

	ssh -t centos@tooling "cd /tmp/dev && mvn clean && cd client && yarn install"
	[[ ${PIPESTATUS[0]} -ne 0 ]] && ERROR

}

function PREPARE_PROD {
	ssh -t centos@tooling "rm -Rf /tmp/prod && git clone /var/lib/jenkins/app_repo.git /tmp/prod"
	
	[[ ${PIPESTATUS[0]} -ne 0 ]] && ERROR
	
	ssh -t centos@tooling ansible-playbook /tmp/prod/ansible/deploy.yaml -e git_branch=origin/production -e git_commit=x -e sdlc_env=PROD --limit prodweb

	[[ ${PIPESTATUS[0]} -ne 0 ]] && ERROR

	curl -v --retry 12 --retry-delay 5  --retry-connrefused http://prodweb:8080/auth/sign-up -H 'Content-Type: application/json' -H 'cache-control:
	no-cache' -d '{
			"username": "patients_admin",
			"firstname": "Patients",
			"lastname": "Admin",
			"password": "delphix"
	}'

	[[ ${PIPESTATUS[0]} -ne 0 ]] && ERROR

	ssh -t centos@tooling snap_prod_refresh_mm --config snap_conf.txt

	[[ ${PIPESTATUS[0]} -ne 0 ]] && ERROR
}

function PREPARE_LOWER {
	echo "Checking that Jenkins is running on tooling"
	until ssh -t centos@tooling "systemctl is-active --quiet jenkins"; do
		echo "Starting Jenkins on tooling"
		ssh -t centos@tooling "sudo systemctl start jenkins"
		sleep 5
	done
	
	ssh -t centos@tooling /var/lib/jenkins/app_repo.git/hooks/post-update
	[[ ${PIPESTATUS[0]} -ne 0 ]] && ERROR

	JOB_URL=http://tooling:8080/job/PatientsPipeline/job/

	JOBS="production master develop"

	for each in $JOBS; do
		GREP_RETURN_CODE=0
		echo checking $each 

		while [ $GREP_RETURN_CODE -eq 0 ]
		do
			JOB_STATUS_URL=${JOB_URL}/${each}/lastBuild/api/json
			sleep 5
			echo "waiting for $each" 
			
			curl --silent $JOB_STATUS_URL 2>/dev/null | grep result\":null > /dev/null
			GREP_RETURN_CODE=$?
		done
	done
}

function PREPARE_LOCAL {
	rm -Rf ~/git/app_repo
	[[ ${PIPESTATUS[0]} -ne 0 ]] && ERROR

	git clone centos@tooling:/var/lib/jenkins/app_repo.git git/app_repo
	[[ ${PIPESTATUS[0]} -ne 0 ]] && ERROR

	cd git/app_repo
	git checkout develop
	[[ ${PIPESTATUS[0]} -ne 0 ]] && ERROR

	rsync -arv ~/notes_changes/* ~/git/app_repo/
	git add -A
	[[ ${PIPESTATUS[0]} -ne 0 ]] && ERROR

}

rm -f ~/Desktop/READY ~/Desktop/WAIT ~/Desktop/ERROR

{
	if [[ -f ~/STAGED ]] ; then
		STAGED
	else
		PRISTINE
	fi
	
	PREPARE_LOCAL

	READY
} 2>&1 | tee ~/Desktop/WAIT

