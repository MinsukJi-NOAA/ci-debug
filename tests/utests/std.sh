if [[ $application == 'global' ]]; then
  if [[ $CI_TEST == 'true' ]]; then
    INPES=3
    JNPES=2
    TASKS=$((INPES*JNPES*6 + WRITE_GROUP*WRTTASK_PER_GROUP))
    RESTART_INTERVAL=$((FHMAX/2))
  fi
elif [[ $application == 'regional' ]]; then
  if [[ $CI_TEST == 'true' ]]; then
    INPES=8
    JNPES=6
    TASKS=$((INPES*JNPES))
    FHMAX=12
    DAYS=0.5
  fi
elif [[ $application == 'cpld' ]]; then
  if [ $CI_TEST == 'true' ]; then
    INPES=2
    JNPES=2
    NPROC_ICE=6
    med_petlist_bounds="0 23"
    atm_petlist_bounds="0 29"
    ocn_petlist_bounds="30 39"
    ice_petlist_bounds="40 45"
    TASKS=$((INPES*JNPES*6 + WRITE_GROUP*WRTTASK_PER_GROUP + 10 + 6))
  fi
fi

NODES=$(((TASKS+TPN-1)/TPN))
(test $CI_TEST == 'true') && source $PATHRT/utests/cmp_proc_bind.sh
##source $PATHRT/utests/cmp_proc_bind.sh
if [[ $RT_SUFFIX =~ std ]]; then
  source $PATHRT/utests/wrt_env.sh
fi
